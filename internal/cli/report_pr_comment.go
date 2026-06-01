package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/jakebromberg/code-audit-pipeline/internal/diffmatch"
	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
	"github.com/jakebromberg/code-audit-pipeline/internal/render"
)

// markerRE constrains --marker values to characters safe inside an HTML
// comment and on a single line. The first character must be alphanumeric
// (forbidding leading `-` / `/` which trigger HTML5 bogus-comment / abrupt-
// closing parser paths). Subsequent characters add `_`, `.`, `:`, `/`,
// `-`. Adjacent `--` is rejected because the HTML5 spec forbids the
// two-dash substring inside `<!-- … -->`. Any other character — `>`,
// `<`, `&`, whitespace, control chars — is rejected so the sticky-
// comment marker stays unambiguous on every line-1 scan.
var markerRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`)

// markerMaxLen bounds the marker length so a marker can never inflate
// `<!-- <marker> -->` past a sensible budget. 128 bytes leaves room for
// `<owner>/<repo>:<workflow>:<id>` patterns while keeping the cap math
// (footerReserve + len(header)) well-defined.
const markerMaxLen = 128

// sizeCapMin is the minimum value accepted for --size-cap-bytes in
// pr-comment mode. Below this, the diagnostic fallback paths
// (truncationFooter's count-only branch, failQuietBody's <unknown> body)
// can't fit within the cap. Rejecting at flag-parse time lets the rest of
// the pipeline assume capBytes >= sizeCapMin, simplifying the cap math.
// 1024 bytes is well above the worst-case minimal-diagnostic envelope
// (~250 bytes for the marker-header + count-only footer with a 128-char
// marker) and small enough to never gate a real workflow.
const sizeCapMin = 1024

// validateMarker reports whether s is a safe sticky-comment marker. Empty
// strings are rejected so callers can distinguish "default" from "unset"
// at flag parsing rather than silently substituting the default.
// Adjacent `--` is rejected via a separate substring check (regex
// alternatives for that constraint are unreadable).
func validateMarker(s string) bool {
	if s == "" || len(s) > markerMaxLen {
		return false
	}
	if strings.Contains(s, "--") {
		return false
	}
	return markerRE.MatchString(s)
}

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
// header's single shape when the row omits it. Returns "" when neither
// is resolvable (multi-shape header AND missing per-row shape, or no
// header AND no per-row shape); rowIsTouched's default branch then
// conservatively drops the row.
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
//
// The repo-relative path can live under either `file` (most queries) or
// `path` (cross-package-backward-imports.jq, which sources its members
// from files.json where the schema uses `.path`). Both are checked; the
// touched-filter doesn't dictate which key a query must use.
func memberIsTouched(m any, touched touchedSet) bool {
	mm, ok := m.(map[string]any)
	if !ok {
		return false
	}
	if t, _ := mm["touched_in_window"].(bool); t {
		return true
	}
	for _, key := range []string{"file", "path"} {
		if f, _ := mm[key].(string); f != "" {
			if _, hit := touched[diffmatch.NormalizePath(f)]; hit {
				return true
			}
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
	// get dropped. truncationFooter self-bounds at this budget via name
	// packing — it adds dropped section names until exhausted, then trails
	// with "(+N more)". 250 bytes leaves room for ~3-4 average-length
	// names + boilerplate + "(+N more)" trailer.
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

	if kept == 0 {
		// Pathological case — even the first section is larger than the
		// effective budget. Surface a notice that fits within the cap AND
		// names the omitted sections (same information the partial-overflow
		// footer provides; finding-4 of iteration-1 review applies here too).
		// truncationFooter is bounded by footerReserve so this body fits.
		return header + truncationFooter(omitted, capBytes, capBytes-len(header))
	}

	if len(omitted) > 0 {
		b.WriteString(truncationFooter(omitted, capBytes, footerReserve))
	}

	return b.String()
}

// truncationFooter renders the "+N section(s) omitted" footer, naming as
// many sections as fit within `budget` bytes. Returns a string ≤ budget.
// Used by the partial-overflow path (footer appended after kept sections)
// and the pathological all-overflow path (footer replaces the body).
func truncationFooter(omitted []string, capBytes, budget int) string {
	if len(omitted) == 0 {
		return ""
	}
	prefix := fmt.Sprintf("\n> %d section(s) omitted to stay under the %d-byte comment cap: ", len(omitted), capBytes)
	suffix := ". See workflow run logs for the full report.\n"
	// Pack as many names as fit, then trail with "(+N more)" when truncated.
	const sep = ", "
	// Truncate individual names to a reasonable length so a single
	// pathologically-long query name (extreme edge case) can't blow the budget.
	const nameMax = 48
	var names []string
	total := len(prefix) + len(suffix)
	for i, n := range omitted {
		if len(n) > nameMax {
			n = truncateRunes(n, nameMax-1) + "…"
		}
		extra := len(n)
		if i > 0 {
			extra += len(sep)
		}
		// Reserve room for a possible "(+N more)" tail if more names follow.
		reserveTail := 0
		if i < len(omitted)-1 {
			reserveTail = len(fmt.Sprintf(" (+%d more)", len(omitted)-i-1))
		}
		if total+extra+reserveTail > budget {
			break
		}
		names = append(names, n)
		total += extra
	}
	if len(names) == 0 {
		// Even the first name didn't fit within the per-name budget — emit
		// a count-only footer. sizeCapMin guarantees capBytes is large
		// enough that the count-only footer (~110 bytes) fits in the
		// caller's budget (which is at minimum capBytes - len(header)
		// >= 1024 - markerMaxLen - "<!-- -->" framing ≈ 880 bytes).
		return fmt.Sprintf("\n> %d section(s) omitted to stay under the %d-byte comment cap. See workflow run logs for the full report.\n", len(omitted), capBytes)
	}
	tail := ""
	if len(names) < len(omitted) {
		tail = fmt.Sprintf(" (+%d more)", len(omitted)-len(names))
	}
	return prefix + strings.Join(names, sep) + tail + suffix
}

// truncateRunes returns the longest prefix of s whose byte length is ≤ maxBytes,
// cut on a rune boundary. Safe for UTF-8 input: never produces invalid
// multi-byte sequences. Used by the truncation footer so a future query name
// containing non-ASCII chars renders cleanly rather than as mojibake.
func truncateRunes(s string, maxBytes int) string {
	if maxBytes <= 0 || s == "" {
		return ""
	}
	if len(s) <= maxBytes {
		return s
	}
	// Start at maxBytes and back up until we land on the first byte of a rune.
	end := maxBytes
	for end > 0 && !utf8.RuneStart(s[end]) {
		end--
	}
	return s[:end]
}

// sectionRender is a per-section rendered body + name pair, accumulated
// before the size-cap pass.
type sectionRender struct {
	name string
	body string
}

// failQuietBody is the comment body emitted when ALL non-skipped sections
// failed (regardless of quiet/loud mode — quiet exits 0, loud exits 1;
// both share this body). Detected-languages list is truncated to fit
// within `capBytes` so the body never exceeds the documented cap.
//
// Wording: "report unavailable" rather than "extraction failed" because
// the underlying failure could be at the extractor, the query engine, or
// the renderer — the PR-comment surface can't distinguish them, and the
// PR author's actionable signal is the same in all three cases (read the
// workflow logs).
func failQuietBody(marker string, detectedLanguages []string, capBytes int) string {
	if marker == "" {
		marker = "code-audit-pipeline-v1"
	}
	header := fmt.Sprintf("<!-- %s -->\n\n", marker)
	prefix := "> code-audit: report unavailable for "
	suffix := "; see workflow run logs.\n"
	noLangsBody := header + prefix + "<unknown>" + suffix
	// sizeCapMin (validated at Report() flag boundary) guarantees capBytes
	// is large enough for noLangsBody plus a reasonable language list.
	if len(detectedLanguages) == 0 {
		return noLangsBody
	}
	// Pack as many language names as fit; truncate with "(+N more)".
	const sep = ", "
	budget := capBytes
	if budget <= 0 {
		budget = 60000
	}
	available := budget - len(header) - len(prefix) - len(suffix)
	var kept []string
	used := 0
	for i, l := range detectedLanguages {
		extra := len(l)
		if i > 0 {
			extra += len(sep)
		}
		reserveTail := 0
		if i < len(detectedLanguages)-1 {
			reserveTail = len(fmt.Sprintf(" (+%d more)", len(detectedLanguages)-i-1))
		}
		if used+extra+reserveTail > available {
			break
		}
		kept = append(kept, l)
		used += extra
	}
	if len(kept) == 0 {
		return noLangsBody
	}
	tail := ""
	if len(kept) < len(detectedLanguages) {
		tail = fmt.Sprintf(" (+%d more)", len(detectedLanguages)-len(kept))
	}
	return header + prefix + strings.Join(kept, sep) + tail + suffix
}
