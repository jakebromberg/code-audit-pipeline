package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/jakebromberg/code-audit-pipeline/internal/diffmatch"
	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
	"github.com/jakebromberg/code-audit-pipeline/internal/render"
)

// markerRE constrains --marker values to characters safe inside an HTML
// comment and on a single line: alphanumerics, dot, dash, underscore,
// colon, slash. Any other character — including `>` (which can prematurely
// close `<!-- … -->`), `<`, `&`, whitespace, or `-->` substrings — is
// rejected so the sticky-comment marker stays unambiguous on every line-1
// scan. Validation happens at the Report() flag boundary; composePRComment
// trusts its input.
var markerRE = regexp.MustCompile(`^[A-Za-z0-9_.:/-]+$`)

// ValidateMarker reports whether s is a safe sticky-comment marker. Empty
// strings are rejected so callers can distinguish "default" from "unset"
// at flag parsing rather than silently substituting the default.
func ValidateMarker(s string) bool { return s != "" && markerRE.MatchString(s) }

// touchedSet is the parsed --touched payload: a set of normalized
// repo-relative paths. Paths are normalized via diffmatch.NormalizePath
// (Go port of extractors/typescript/_lib/walk-predicate.mjs:34 normalizePath)
// so they compare byte-equal against catalog `.file` entries.
type touchedSet map[string]struct{}

// loadTouchedSet reads --touched <path>, expects a JSON array of strings,
// normalizes each entry. Validation rules:
//   - File missing/unreadable: returns error (caller exits 2 — usage error).
//   - JSON parse failure: returns error (caller exits 2).
//   - Top-level value is not an array: returns error (caller exits 2).
//   - Any element is not a string: returns error citing the offending index.
//   - Empty array: returns an empty (non-nil) set. The renderer treats this
//     as "no files touched" — every cluster is filtered out and the
//     "no structural impact" body is emitted.
//
// Caller errors fail loud (exit 2) so the workflow author fixes the
// resolve-touched.sh step rather than the comment surface silently
// degrading.
func loadTouchedSet(path string) (touchedSet, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("--touched %s: %w", path, err)
	}
	// Decode into an `any` first so we can distinguish the three top-level
	// shapes Go's json package accepts: JSON `null` (raw == nil), a JSON
	// array (raw == []any), or anything else (object/string/number/bool).
	// Unmarshalling directly into []any would silently accept `null` as a
	// nil slice — the bug surfaced in code-review verifier candidate #2.
	var raw any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("--touched %s: parse JSON: %w", path, err)
	}
	if raw == nil {
		return nil, fmt.Errorf("--touched %s: top-level value is JSON null; want a JSON array of strings", path)
	}
	arr, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("--touched %s: top-level value is %T; want a JSON array of strings", path, raw)
	}
	set := make(touchedSet, len(arr))
	for i, v := range arr {
		s, ok := v.(string)
		if !ok {
			return nil, fmt.Errorf("--touched %s: element [%d] is %T, want string", path, i, v)
		}
		n := diffmatch.NormalizePath(s)
		if n == "" {
			continue
		}
		set[n] = struct{}{}
	}
	return set, nil
}

// filterRowsByTouched drops rows where no participant has
// touched_in_window=true AND no participant's normalized .file is in the
// touched set. Dispatches per-row by `row["shape"]` (cluster / pair /
// metric), NOT per-query header.Shape: dual-shape queries like
// function-duplicates.jq emit both cluster and pair rows in the same
// JSONL stream, and applying a cluster-only predicate to pair rows would
// silently drop every pair row whose members[] field is absent. See
// docs/pipeline-contract.md §"Cluster envelope (post-PR-1, ADR-0003)".
//
// touched == nil short-circuits to pass-through (no filtering requested).
//
// Header is accepted but only used as a fallback when row["shape"] is
// absent — older catalogs / synthetic test rows may not carry it. New
// queries are required to emit `shape:` per ADR-0003.
func filterRowsByTouched(rows []render.Row, header *frontmatter.Header, touched touchedSet) []render.Row {
	if touched == nil {
		return rows
	}
	out := make([]render.Row, 0, len(rows))
	for _, row := range rows {
		shape := rowShape(row, header)
		if rowIsTouched(row, shape, touched) {
			out = append(out, row)
		}
	}
	return out
}

// rowShape resolves a row's shape: prefer the row-level `shape` field
// (per-row dispatch, the ADR-0003 contract), fall back to the query
// header's single shape when the row omits it. Falls back to "cluster"
// only when the header itself is missing (defensive for synthetic
// fixtures); the unknown-shape branch in rowIsTouched then conservatively
// drops the row.
func rowShape(row render.Row, header *frontmatter.Header) string {
	if s, ok := row["shape"].(string); ok && s != "" {
		return s
	}
	if header != nil && len(header.Shape) == 1 {
		return header.Shape[0]
	}
	return ""
}

// rowIsTouched dispatches the touched-set predicate by shape. Unknown or
// missing shape conservatively drops the row — we'd rather omit a row
// from a PR comment than surface one we can't reason about.
func rowIsTouched(row render.Row, shape string, touched touchedSet) bool {
	// Envelope-level touched_in_window short-circuits regardless of shape.
	// Some queries may surface a roll-up flag on the row envelope; honor it.
	if t, _ := row["touched_in_window"].(bool); t {
		return true
	}
	switch shape {
	case "cluster":
		return clusterRowIsTouched(row, touched)
	case "pair":
		return pairRowIsTouched(row, touched)
	case "metric":
		// Metric rows are query-level summaries; they don't carry per-file
		// payload to gate on. The touched-window-debt-summary metric is
		// already a "did anything in the audit window get touched" roll-up,
		// so a metric row is INCLUDED when --touched is set (it's the
		// summary the PR author wants to see) — the metric self-filters its
		// own nested `touched_clusters[]` payload via the query body.
		return true
	default:
		return false
	}
}

// clusterRowIsTouched returns true if any cluster member has
// touched_in_window=true or has a normalized .file in the touched set.
// The "members" key is the cluster envelope's reserved field per
// docs/pipeline-contract.md §"Cluster envelope"; queries must emit
// participants under this key for the touched-filter to see them.
func clusterRowIsTouched(row render.Row, touched touchedSet) bool {
	rawMembers, ok := row["members"].([]any)
	if !ok {
		return false
	}
	for _, m := range rawMembers {
		if memberIsTouched(m, touched) {
			return true
		}
	}
	return false
}

// pairRowIsTouched returns true if either pair endpoint (`left` / `right`)
// has touched_in_window=true or has a normalized .file in the touched
// set. Per the cluster-envelope contract, pair rows carry their two
// endpoints under the `left` and `right` reserved fields.
func pairRowIsTouched(row render.Row, touched touchedSet) bool {
	return memberIsTouched(row["left"], touched) || memberIsTouched(row["right"], touched)
}

// memberIsTouched is the per-participant predicate shared by
// clusterRowIsTouched and pairRowIsTouched. Accepts the JSON-unmarshalled
// `any` so it can take both members[i] (typically map[string]any) and a
// nested left/right value.
func memberIsTouched(m any, touched touchedSet) bool {
	mm, ok := m.(map[string]any)
	if !ok {
		return false
	}
	if t, _ := mm["touched_in_window"].(bool); t {
		return true
	}
	if f, _ := mm["file"].(string); f != "" {
		if _, hit := touched[diffmatch.NormalizePath(f)]; hit {
			return true
		}
	}
	return false
}

// prCommentOpts is the comment-mode composition configuration. Populated
// from CLI flags by Report().
type prCommentOpts struct {
	marker       string
	sizeCapBytes int
}

// composePRComment renders the per-PR comment body. Differs from
// composeReport in five ways:
//
//  1. Sticky marker line as the first line (so marocchino's `header:`
//     substring scan matches).
//  2. No "Generated by code-audit …" timestamp/version header — the
//     comment is updated in place across force-pushes; a timestamp would
//     thrash the marocchino diff check every run.
//  3. No "Skipped queries" footer — runtime errors that landed queries in
//     the skipped list are not actionable from the PR-comment surface.
//     They go to stderr (the runner log) instead.
//  4. Per-section size cap with alphabetical-prefix preservation: when
//     the next section would exceed the budget, ALL further sections are
//     dropped (loop breaks). This guarantees the kept set is a contiguous
//     alphabetical prefix and the truncation footer names which sections
//     were omitted so the PR author can find them in the workflow logs.
//  5. Empty-results path: when no section produced any rows (e.g. every
//     cluster was filtered out by --touched), the body is the marker line
//     plus a "no structural impact" notice so the sticky comment still
//     updates and reads sensibly.
//
// Sections render in deterministic query-name order (alphabetical,
// matching listQueries). Given identical inputs, the output is byte-
// reproducible.
//
// The input `results` slice is NOT mutated; sorting happens on a local
// copy so callers can pass shared slices safely.
//
// Caller is responsible for the fail-quiet exit path (see Report()).
func composePRComment(results []sectionResult, opts prCommentOpts) string {
	marker := opts.marker
	if marker == "" {
		marker = "code-audit-pipeline-v1"
	}
	capBytes := opts.sizeCapBytes
	if capBytes <= 0 {
		capBytes = 60000
	}

	// Sort a local copy so we never mutate the caller's slice.
	sorted := make([]sectionResult, len(results))
	copy(sorted, results)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].name < sorted[j].name })

	header := fmt.Sprintf("<!-- %s -->\n\n", marker)

	var rendered []sectionRender
	for _, r := range sorted {
		if r.err != nil || r.skipped != "" || len(r.blocks) == 0 {
			continue
		}
		if r.header == nil {
			// Defensive: rendering relies on header.Desc and header.Shape.
			// Skip rather than panic when an upstream producer violates the
			// implicit invariant that blocks!=nil ⇒ header!=nil.
			continue
		}
		var sec strings.Builder
		fmt.Fprintf(&sec, "## %s\n\n", r.name)
		desc := strings.TrimRight(r.header.Desc, ".")
		shape := strings.Join(r.header.Shape, ", ")
		fmt.Fprintf(&sec, "_%s. %d row(s), shape: %s._\n\n", desc, len(r.blocks), shape)
		for _, block := range r.blocks {
			sec.WriteString(block)
			sec.WriteString("\n")
		}
		rendered = append(rendered, sectionRender{name: r.name, body: sec.String()})
	}

	if len(rendered) == 0 {
		return header + "_No structural impact: no cluster contains a file touched by this PR._\n"
	}

	// Reserve a fixed-size envelope for the truncation footer so the
	// final body never exceeds capBytes regardless of how many sections
	// get dropped. The actual footer is bounded by the longest of the
	// truncated-by-cap and capability-overrun variants below; 250 bytes
	// covers the section-list interpolation up to ~10 dropped names plus
	// the surrounding boilerplate.
	const footerReserve = 250
	effective := capBytes - footerReserve - len(header)
	if effective < 0 {
		effective = 0
	}

	var b strings.Builder
	b.WriteString(header)

	used := 0
	kept := 0
	var omitted []string
	dropFromHere := false
	for _, sec := range rendered {
		if dropFromHere {
			omitted = append(omitted, sec.name)
			continue
		}
		if used+len(sec.body) > effective {
			// First section that doesn't fit. Drop it AND every later
			// section so the kept set stays an alphabetical prefix and
			// later (smaller) sections don't sneak past dropped earlier
			// (larger) sections — a non-obvious ordering surprise the
			// PR-comment reader couldn't recover from.
			dropFromHere = true
			omitted = append(omitted, sec.name)
			continue
		}
		b.WriteString(sec.body)
		used += len(sec.body)
		kept++
	}

	if len(omitted) > 0 {
		// Name the dropped sections so the PR author can find them in the
		// workflow logs. Cap the list at the first few to keep the footer
		// within the reserved envelope; the count is always exact.
		const maxNames = 6
		names := omitted
		suffix := ""
		if len(names) > maxNames {
			names = names[:maxNames]
			suffix = fmt.Sprintf(" (+%d more)", len(omitted)-maxNames)
		}
		footer := fmt.Sprintf(
			"\n> +%d section(s) omitted to stay under the %d-byte comment cap: %s%s. See workflow run logs for the full report.\n",
			len(omitted), capBytes, strings.Join(names, ", "), suffix,
		)
		b.WriteString(footer)
	}

	if kept == 0 {
		// Pathological case — even the first section is larger than the
		// effective budget. Surface a notice that fits within the cap so
		// the comment still reads sensibly.
		return header + fmt.Sprintf("> code-audit: report exceeds the %d-byte comment cap; see workflow logs.\n", capBytes)
	}

	return b.String()
}

// sectionRender is a per-section rendered body + name pair, accumulated
// before the size-cap pass.
type sectionRender struct {
	name string
	body string
}

// failQuietBody is the comment body emitted in --mode pr-comment
// --on-extraction-failure quiet when one or more upstream pipeline
// errors occurred. detectedLanguages may be empty.
func failQuietBody(marker string, detectedLanguages []string) string {
	if marker == "" {
		marker = "code-audit-pipeline-v1"
	}
	langs := strings.Join(detectedLanguages, ", ")
	if langs == "" {
		langs = "<unknown>"
	}
	return fmt.Sprintf(
		"<!-- %s -->\n\n> code-audit: extraction failed for %s; see workflow run logs.\n",
		marker, langs,
	)
}
