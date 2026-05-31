// findnextinstance.go implements `audit find-next-instance`: given a closed
// PR, surface other catalog members whose before-shape matches the PR diff's
// removed lines.
//
// Pipeline:
//
//	gh pr diff (or --diff file)
//	  → diffparse.Parse
//	    → per-hunk classify (function-body | type-shape | …)
//	      → diffmatch.{FunctionBodyMatches, TypeShapeMatches}
//	        → render text or jsonl (pair / metric envelope)
//
// See plans/issue-225-find-next-instance-plan.md for the design.
package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/diffmatch"
	"github.com/jakebromberg/code-audit-pipeline/internal/diffparse"
	"github.com/jakebromberg/code-audit-pipeline/internal/ghclient"
)

// FindNextInstance implements `audit find-next-instance`.
//
// Flags mirror the issue-225 plan. Returns standard audit exit codes:
//
//	0  success (including "no matches")
//	1  runtime failure (diff fetch / catalog read / serialization)
//	2  usage error
//	3  catalog / discovery error (mirrors audit query)
func FindNextInstance(ctx context.Context, argv []string, stdout io.Writer) int {
	fset := flag.NewFlagSet("find-next-instance", flag.ContinueOnError)
	prFlag := fset.Int("pr", 0, "PR number to fetch via gh pr diff")
	repoFlag := fset.String("repo", "", "owner/repo (default: derived from cwd)")
	diffPath := fset.String("diff", "", "read unified diff from file instead of gh")
	kindFlag := fset.String("kind", "all", "restrict to function-body | type-shape | all")
	minMatchLines := fset.Int("min-match-lines", 3, "min intersection lines for a function-body match")
	minJaccard := fset.Float64("min-jaccard", 0.6, "min Jaccard score for a match (function-body and type-shape)")
	minShapeFields := fset.Int("min-shape-fields", 2, "min number of removed fields a type-shape match must cover")
	format := fset.String("format", "text", "output format: text or jsonl")
	rootFlag := fset.String("root", "", "audit root (defaults to cwd)")
	fnCatalogPath := fset.String("function-catalog", "", "explicit function-catalog override")
	tyCatalogPath := fset.String("type-catalog", "", "explicit type-catalog override")
	if err := fset.Parse(argv); err != nil {
		return 2
	}

	if *format != "text" && *format != "jsonl" {
		fmt.Fprintf(stdout, "audit: --format must be text or jsonl, got %q\n", *format)
		return 2
	}
	if *kindFlag != "all" && *kindFlag != "function-body" && *kindFlag != "type-shape" {
		fmt.Fprintf(stdout, "audit: --kind must be one of all|function-body|type-shape, got %q\n", *kindFlag)
		return 2
	}
	if *prFlag == 0 && *diffPath == "" {
		fmt.Fprintln(stdout, "audit: --pr or --diff is required")
		return 2
	}

	root := *rootFlag
	if root == "" {
		cwd, _ := os.Getwd()
		root = cwd
	}
	absRoot, _ := filepath.Abs(root)

	// Acquire diff.
	diffText, repo, prNum, err := acquireDiff(ctx, *diffPath, *prFlag, *repoFlag, absRoot)
	if err != nil {
		fmt.Fprintf(stdout, "audit: %v\n", err)
		return 1
	}

	files, err := diffparse.Parse(strings.NewReader(diffText))
	if err != nil {
		fmt.Fprintf(stdout, "audit: parse diff: %v\n", err)
		return 1
	}

	// Load catalogs (only the ones the requested kind needs).
	var fnRows []diffmatch.FunctionRow
	var tyRows []diffmatch.TypeRow
	if *kindFlag == "all" || *kindFlag == "function-body" {
		fnRows, err = loadFunctionCatalog(absRoot, *fnCatalogPath)
		if err != nil {
			fmt.Fprintf(stdout, "audit: %v\n", err)
			return 3
		}
	}
	if *kindFlag == "all" || *kindFlag == "type-shape" {
		tyRows, err = loadTypeCatalog(absRoot, *tyCatalogPath)
		if err != nil {
			fmt.Fprintf(stdout, "audit: %v\n", err)
			return 3
		}
	}

	// Build location index for self-match exclusion + PR-source resolution.
	fnByLoc := indexFunctionsByLocation(fnRows)
	tyByLoc := indexTypesByLocation(tyRows)

	rows := classifyAndMatch(files, prNum, repo, *kindFlag, *minMatchLines, *minJaccard, *minShapeFields, fnRows, tyRows, fnByLoc, tyByLoc)

	return emit(stdout, *format, rows, prNum, repo)
}

// acquireDiff returns the diff text, the resolved repo, and the PR number.
// For --diff <path>, the PR number defaults to --pr (which may be 0) and the
// repo defaults to --repo (which may be "").
func acquireDiff(ctx context.Context, diffPath string, pr int, repo, absRoot string) (string, string, int, error) {
	if diffPath != "" {
		data, err := os.ReadFile(diffPath)
		if err != nil {
			return "", "", 0, fmt.Errorf("read diff: %w", err)
		}
		return string(data), repo, pr, nil
	}
	client := ghclient.New()
	if repo == "" {
		nm, err := client.RepoNameWithOwner(ctx, absRoot)
		if err != nil {
			if errors.Is(err, ghclient.ErrGHNotInstalled) {
				return "", "", 0, err
			}
			return "", "", 0, fmt.Errorf("resolve --repo (pass explicitly): %w", err)
		}
		repo = nm
	}
	diff, err := client.PRDiff(ctx, absRoot, repo, pr)
	if err != nil {
		return "", "", 0, err
	}
	return diff, repo, pr, nil
}

// loadFunctionCatalog mirrors the catalog-resolution / error-message pattern
// from internal/cli/common.go's wireCatalogs.
func loadFunctionCatalog(absRoot, override string) ([]diffmatch.FunctionRow, error) {
	path := override
	if path == "" {
		cache, err := auditdir.Open(absRoot, Version)
		if err != nil {
			return nil, err
		}
		p, ok := cache.CatalogPath("function-catalog")
		if !ok {
			return nil, fmt.Errorf("catalog %q not cached under .audit/ — run `audit extract` or pass --function-catalog <path>", "function-catalog")
		}
		path = p
	}
	return decodeFunctionCatalog(path)
}

func loadTypeCatalog(absRoot, override string) ([]diffmatch.TypeRow, error) {
	path := override
	if path == "" {
		cache, err := auditdir.Open(absRoot, Version)
		if err != nil {
			return nil, err
		}
		p, ok := cache.CatalogPath("type-catalog")
		if !ok {
			return nil, fmt.Errorf("catalog %q not cached under .audit/ — run `audit extract` or pass --type-catalog <path>", "type-catalog")
		}
		path = p
	}
	return decodeTypeCatalog(path)
}

// catalogWrapper is the v1.1+ envelope. find-next-instance accepts either
// the wrapper or a bare v1.0 array — matching the tolerance already in
// pipeline/queries/_canonical.jq's `entries` helper. Schema-version checks
// accept any "1.x" so an additive minor bump doesn't break us.
type catalogWrapper struct {
	SchemaVersion string          `json:"schema_version"`
	Entries       json.RawMessage `json:"entries"`
}

// decodeCatalogEntries returns the raw entries JSON from `data`. Accepts:
//   - v1.1+ wrapper {"schema_version":"1.x", "entries":[…]}
//   - v1.0 bare array […]
//
// Rejects a wrapper whose schema_version is missing or not 1.x. A v1.0
// bare array carries no version and is accepted on shape.
func decodeCatalogEntries(data []byte, kind string) (json.RawMessage, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, fmt.Errorf("%s: empty catalog", kind)
	}
	// Discriminate on the first non-whitespace byte.
	for _, b := range data {
		switch b {
		case ' ', '\t', '\n', '\r':
			continue
		case '[':
			return json.RawMessage(data), nil
		case '{':
			w := catalogWrapper{}
			if err := json.Unmarshal(data, &w); err != nil {
				return nil, fmt.Errorf("decode %s wrapper: %w", kind, err)
			}
			if !strings.HasPrefix(w.SchemaVersion, "1.") {
				return nil, fmt.Errorf("%s schema_version=%q, find-next-instance requires 1.x", kind, w.SchemaVersion)
			}
			if len(w.Entries) == 0 {
				return nil, fmt.Errorf("%s: wrapper missing or empty entries", kind)
			}
			return w.Entries, nil
		default:
			return nil, fmt.Errorf("%s: top-level JSON must be array or object, got %q", kind, string(b))
		}
	}
	return nil, fmt.Errorf("%s: empty catalog", kind)
}

func decodeFunctionCatalog(path string) ([]diffmatch.FunctionRow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read function-catalog: %w", err)
	}
	entries, err := decodeCatalogEntries(data, "function-catalog")
	if err != nil {
		return nil, err
	}
	var rows []diffmatch.FunctionRow
	if err := json.Unmarshal(entries, &rows); err != nil {
		return nil, fmt.Errorf("decode function-catalog entries: %w", err)
	}
	return rows, nil
}

func decodeTypeCatalog(path string) ([]diffmatch.TypeRow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read type-catalog: %w", err)
	}
	entries, err := decodeCatalogEntries(data, "type-catalog")
	if err != nil {
		return nil, err
	}
	var rows []diffmatch.TypeRow
	if err := json.Unmarshal(entries, &rows); err != nil {
		return nil, fmt.Errorf("decode type-catalog entries: %w", err)
	}
	return rows, nil
}

func indexFunctionsByLocation(rows []diffmatch.FunctionRow) map[string][]diffmatch.FunctionRow {
	m := make(map[string][]diffmatch.FunctionRow, len(rows))
	for _, r := range rows {
		m[r.File] = append(m[r.File], r)
	}
	for k := range m {
		sort.Slice(m[k], func(i, j int) bool { return m[k][i].Line < m[k][j].Line })
	}
	return m
}

func indexTypesByLocation(rows []diffmatch.TypeRow) map[string][]diffmatch.TypeRow {
	m := make(map[string][]diffmatch.TypeRow, len(rows))
	for _, r := range rows {
		m[r.File] = append(m[r.File], r)
	}
	for k := range m {
		sort.Slice(m[k], func(i, j int) bool { return m[k][i].Line < m[k][j].Line })
	}
	return m
}

// outRow is the canonical envelope payload for one emitted candidate.
// shape == "pair" when both PR-source and candidate resolve to a catalog
// member. shape == "cluster" (single member: the candidate) when the
// PR-source can't be resolved — preserves the matched candidate's
// catalog-shaped data without violating the contract's reservation of
// `left`/`right` for pair rows.
//
// Score field is named `jacc` to match the convention every existing pair
// query uses (function-duplicates.jq, near-duplicates.jq, etc.) and the
// percent-format the shared `render.Pair` header expects.
type outRow struct {
	ClusterID        string                   `json:"cluster_id"`
	Query            string                   `json:"query"`
	Shape            string                   `json:"shape"`
	MatchKind        string                   `json:"match_kind"`
	Jacc             float64                  `json:"jacc,omitempty"`
	Left             map[string]interface{}   `json:"left,omitempty"`
	Right            map[string]interface{}   `json:"right,omitempty"`
	Members          []map[string]interface{} `json:"members,omitempty"`
	PRNumber         int                      `json:"pr_number,omitempty"`
	PRRepo           string                   `json:"pr_repo,omitempty"`
	PRHunkOldStart   int                      `json:"pr_hunk_old_start,omitempty"`
	PRHunkOldLines   int                      `json:"pr_hunk_old_lines,omitempty"`
	Intersection     int                      `json:"intersection,omitempty"`
	Union            int                      `json:"union,omitempty"`
	RemovedLineCount int                      `json:"removed_line_count,omitempty"`
	SourceFile       string                   `json:"source_file,omitempty"`
	Notes            string                   `json:"notes,omitempty"`
}

func classifyAndMatch(
	files []diffparse.FileDiff,
	pr int, repo string,
	kindRestriction string,
	minMatchLines int, minJaccard float64, minShapeFields int,
	fnRows []diffmatch.FunctionRow,
	tyRows []diffmatch.TypeRow,
	fnByLoc map[string][]diffmatch.FunctionRow,
	tyByLoc map[string][]diffmatch.TypeRow,
) []outRow {
	var out []outRow
	for _, f := range files {
		for _, h := range f.Hunks {
			source := f.Path()
			hunkStart, hunkEnd := h.OldStart, h.OldStart+h.OldLines
			// function-body
			if kindRestriction == "all" || kindRestriction == "function-body" {
				removedNorm := diffmatch.Normalize(h.Removed)
				if len(removedNorm) >= minMatchLines {
					srcFn := enclosingFunction(fnByLoc, source, hunkStart, hunkEnd)
					matches := diffmatch.FunctionBodyMatches(fnRows, removedNorm, minMatchLines, minJaccard, srcLocFile(srcFn), srcLocLine(srcFn))
					for _, m := range matches {
						out = append(out, buildFunctionRow(pr, repo, source, h, m, srcFn))
					}
				}
			}
			// type-shape
			if kindRestriction == "all" || kindRestriction == "type-shape" {
				names := diffmatch.ExtractRemovedFieldNames(h.Removed)
				if len(names) >= minShapeFields {
					srcTy := enclosingType(tyByLoc, source, hunkStart, hunkEnd)
					// Honors the user's --min-jaccard and --min-shape-fields.
					matches := diffmatch.TypeShapeMatches(tyRows, names, minShapeFields, minJaccard, srcLocFileTy(srcTy), srcLocLineTy(srcTy))
					for _, m := range matches {
						out = append(out, buildTypeRow(pr, repo, source, h, m, srcTy, names))
					}
				}
			}
		}
	}
	// Stable global rank: function-body before type-shape, then by score desc.
	sort.SliceStable(out, func(i, j int) bool {
		ai, aj := matchKindRank(out[i].MatchKind), matchKindRank(out[j].MatchKind)
		if ai != aj {
			return ai < aj
		}
		if out[i].Jacc != out[j].Jacc {
			return out[i].Jacc > out[j].Jacc
		}
		return out[i].ClusterID < out[j].ClusterID
	})
	return out
}

func matchKindRank(k string) int {
	switch k {
	case "function-body":
		return 0
	case "type-shape":
		return 1
	case "convention-swap":
		return 2
	default:
		return 9
	}
}

// enclosingFunction returns the catalog row whose body span overlaps the
// hunk's old-file range `[hunkStart, hunkEnd)`. Overlap is the right join
// because the hunk's OldStart is typically a leading-context line (often
// the function's declaration), but the actual changes can be anywhere
// within the range. A row qualifies when:
//
//	row.Line < hunkEnd  AND  hunkStart < row.Line + bodySpan
//
// where bodySpan is the row's BodyLineCount when available, else the gap
// to the next row's declaration. When several rows overlap (nested-function
// case), the one with the highest Line wins (innermost).
//
// Returns nil when no row's body overlaps the hunk range — preventing the
// prior "latest-declared-before" behavior from misattributing hunks that
// landed between functions.
func enclosingFunction(idx map[string][]diffmatch.FunctionRow, file string, hunkStart, hunkEnd int) *diffmatch.FunctionRow {
	rows := idx[file]
	if len(rows) == 0 {
		return nil
	}
	var best *diffmatch.FunctionRow
	for i := range rows {
		if rows[i].Line >= hunkEnd {
			break
		}
		upper := -1
		if rows[i].BodyLineCount != nil {
			upper = rows[i].Line + *rows[i].BodyLineCount
		} else if i+1 < len(rows) {
			upper = rows[i+1].Line
		}
		if upper > 0 && hunkStart >= upper {
			continue
		}
		// rows[i] overlaps [hunkStart, hunkEnd). Innermost wins (later
		// in the sorted list).
		best = &rows[i]
	}
	return best
}

// enclosingType mirrors enclosingFunction. TypeRow has no explicit body
// span, so the upper bound is the next row's declaration line.
func enclosingType(idx map[string][]diffmatch.TypeRow, file string, hunkStart, hunkEnd int) *diffmatch.TypeRow {
	rows := idx[file]
	if len(rows) == 0 {
		return nil
	}
	var best *diffmatch.TypeRow
	for i := range rows {
		if rows[i].Line >= hunkEnd {
			break
		}
		upper := -1
		if i+1 < len(rows) {
			upper = rows[i+1].Line
		}
		if upper > 0 && hunkStart >= upper {
			continue
		}
		best = &rows[i]
	}
	return best
}

func srcLocFile(srcFn *diffmatch.FunctionRow) string {
	if srcFn == nil {
		return ""
	}
	return srcFn.File
}
func srcLocLine(srcFn *diffmatch.FunctionRow) int {
	if srcFn == nil {
		return 0
	}
	return srcFn.Line
}
func srcLocFileTy(srcTy *diffmatch.TypeRow) string {
	if srcTy == nil {
		return ""
	}
	return srcTy.File
}
func srcLocLineTy(srcTy *diffmatch.TypeRow) int {
	if srcTy == nil {
		return 0
	}
	return srcTy.Line
}

func buildFunctionRow(pr int, repo, source string, h diffparse.Hunk, m diffmatch.FunctionMatch, srcFn *diffmatch.FunctionRow) outRow {
	row := outRow{
		Query:            "find-next-instance",
		MatchKind:        "function-body",
		Jacc:             m.Jaccard,
		PRNumber:         pr,
		PRRepo:           repo,
		PRHunkOldStart:   h.OldStart,
		PRHunkOldLines:   h.OldLines,
		Intersection:     m.Intersection,
		Union:            m.Union,
		RemovedLineCount: len(diffmatch.Normalize(h.Removed)),
		SourceFile:       source,
	}
	right := memberFromFunctionRow(m.Row)
	// Hunk anchor is folded into cluster_id so two distinct hunks against
	// the same (srcFn, candidate) pair don't collide on the within-query
	// uniqueness invariant (pipeline-contract.md §"On cluster_id uniqueness").
	hunkKey := "@" + iToA(h.OldStart)
	if srcFn != nil {
		row.Shape = "pair"
		row.Left = memberFromFunctionRow(*srcFn)
		row.Right = right
		row.ClusterID = "find-next-instance:" + loc(*srcFn) + hunkKey + "__" + loc(m.Row)
	} else {
		// PR-source not in the catalog (file deleted, kind unindexed, etc.).
		// Emit as single-member cluster so the candidate's catalog-shaped
		// data is preserved in a contract-compliant envelope (see
		// pipeline-contract.md §"Cluster envelope" — single-member rows are
		// allowed, e.g. orphan-infer-model).
		row.Shape = "cluster"
		row.Members = []map[string]interface{}{right}
		row.Notes = "PR-source location not resolved to a function-catalog entry"
		row.ClusterID = "find-next-instance:" + source + ":" + iToA(h.OldStart) + "__" + loc(m.Row)
	}
	return row
}

func buildTypeRow(pr int, repo, source string, h diffparse.Hunk, m diffmatch.TypeShapeMatch, srcTy *diffmatch.TypeRow, removedFields []string) outRow {
	row := outRow{
		Query:            "find-next-instance",
		MatchKind:        "type-shape",
		Jacc:             m.Jaccard,
		PRNumber:         pr,
		PRRepo:           repo,
		PRHunkOldStart:   h.OldStart,
		PRHunkOldLines:   h.OldLines,
		Intersection:     m.Intersection,
		Union:            m.Union,
		RemovedLineCount: len(removedFields),
		SourceFile:       source,
	}
	right := memberFromTypeRow(m.Row)
	hunkKey := "@" + iToA(h.OldStart)
	if srcTy != nil {
		row.Shape = "pair"
		row.Left = memberFromTypeRow(*srcTy)
		row.Right = right
		row.ClusterID = "find-next-instance:" + locTy(*srcTy) + hunkKey + "__" + locTy(m.Row)
	} else {
		row.Shape = "cluster"
		row.Members = []map[string]interface{}{right}
		row.Notes = "PR-source location not resolved to a type-catalog entry"
		row.ClusterID = "find-next-instance:" + source + ":" + iToA(h.OldStart) + "__" + locTy(m.Row)
	}
	return row
}

// memberFromFunctionRow returns the catalog fields renderMember consumes
// (cluster.go's memberInlineKeys lists async, param_count; the leading `*`
// marker uses touched_in_window) plus the standard filter flags downstream
// consumers expect on member objects.
func memberFromFunctionRow(r diffmatch.FunctionRow) map[string]interface{} {
	return map[string]interface{}{
		"name":              r.Name,
		"kind":              r.Kind,
		"package":           r.Package,
		"file":              r.File,
		"line":              r.Line,
		"async":             r.Async,
		"param_count":       r.ParamCount,
		"touched_in_window": r.TouchedInWindow,
		"is_test":           r.IsTest,
		"generated":         r.Generated,
	}
}

func memberFromTypeRow(r diffmatch.TypeRow) map[string]interface{} {
	return map[string]interface{}{
		"name":              r.Name,
		"kind":              r.Kind,
		"package":           r.Package,
		"file":              r.File,
		"line":              r.Line,
		"touched_in_window": r.TouchedInWindow,
		"is_test":           r.IsTest,
		"generated":         r.Generated,
	}
}

func loc(r diffmatch.FunctionRow) string {
	return r.Package + ":" + r.File + ":" + iToA(r.Line) + ":" + r.Name
}
func locTy(r diffmatch.TypeRow) string {
	return r.Package + ":" + r.File + ":" + iToA(r.Line) + ":" + r.Name
}

func iToA(n int) string {
	// Avoid pulling strconv for one call.
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func emit(out io.Writer, format string, rows []outRow, pr int, repo string) int {
	if format == "jsonl" {
		// JSONL: write to a buffer first so encode failures (which are
		// vanishingly unlikely with the typed `outRow` we control) never
		// corrupt the output stream mid-write. Errors go to stderr.
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		for _, r := range rows {
			if err := enc.Encode(r); err != nil {
				fmt.Fprintf(os.Stderr, "audit: encode row %q: %v\n", r.ClusterID, err)
				return 1
			}
		}
		if _, err := io.Copy(out, &buf); err != nil {
			fmt.Fprintf(os.Stderr, "audit: write jsonl: %v\n", err)
			return 1
		}
		return 0
	}
	// Text.
	header := "=== find-next-instance"
	if pr != 0 {
		header += fmt.Sprintf(": PR #%d", pr)
	}
	if repo != "" {
		header += " — " + repo
	}
	header += fmt.Sprintf(" (%d candidate(s)) ===\n", len(rows))
	io.WriteString(out, header)
	for _, r := range rows {
		// Pick the candidate member: pair rows carry it on Right; cluster
		// rows (unresolved PR-source) carry it as Members[0].
		var candidate map[string]interface{}
		switch r.Shape {
		case "pair":
			candidate = r.Right
		case "cluster":
			if len(r.Members) > 0 {
				candidate = r.Members[0]
			}
		}
		fmt.Fprintf(out, "\n[%s] %d%%  ", r.MatchKind, int(r.Jacc*100))
		if candidate != nil {
			fmt.Fprintf(out, "%s:%s:%v:%s\n",
				candidate["package"], candidate["file"], candidate["line"], candidate["name"])
		} else {
			fmt.Fprintln(out)
		}
		fmt.Fprintf(out, "    intersection=%d / union=%d  removed=%d\n",
			r.Intersection, r.Union, r.RemovedLineCount)
		fmt.Fprintf(out, "    source: %s @%d (%d removed lines)\n",
			r.SourceFile, r.PRHunkOldStart, r.PRHunkOldLines)
		fmt.Fprintf(out, "    cid=%s\n", r.ClusterID)
		if r.Notes != "" {
			fmt.Fprintf(out, "    notes: %s\n", r.Notes)
		}
	}
	return 0
}
