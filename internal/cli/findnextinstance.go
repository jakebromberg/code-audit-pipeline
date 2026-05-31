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
	minJaccard := fset.Float64("min-jaccard", 0.6, "min Jaccard score for a match")
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

	rows := classifyAndMatch(files, prNum, repo, *kindFlag, *minMatchLines, *minJaccard, fnRows, tyRows, fnByLoc, tyByLoc)

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
	diff, err := client.PRDiff(ctx, repo, pr)
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

// catalogWrapper is the v1.1 envelope. We accept "1.1" only; pre-v1.1
// bare-array catalogs require a different decode path that the binary's
// other queries also don't support natively.
type catalogWrapper struct {
	SchemaVersion string            `json:"schema_version"`
	Entries       json.RawMessage   `json:"entries"`
}

func decodeFunctionCatalog(path string) ([]diffmatch.FunctionRow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read function-catalog: %w", err)
	}
	w := catalogWrapper{}
	if err := json.Unmarshal(data, &w); err != nil {
		return nil, fmt.Errorf("decode function-catalog wrapper: %w", err)
	}
	if w.SchemaVersion != "1.1" {
		return nil, fmt.Errorf("function-catalog schema_version=%q, find-next-instance requires \"1.1\"", w.SchemaVersion)
	}
	var rows []diffmatch.FunctionRow
	if err := json.Unmarshal(w.Entries, &rows); err != nil {
		return nil, fmt.Errorf("decode function-catalog entries: %w", err)
	}
	return rows, nil
}

func decodeTypeCatalog(path string) ([]diffmatch.TypeRow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read type-catalog: %w", err)
	}
	w := catalogWrapper{}
	if err := json.Unmarshal(data, &w); err != nil {
		return nil, fmt.Errorf("decode type-catalog wrapper: %w", err)
	}
	if w.SchemaVersion != "1.1" {
		return nil, fmt.Errorf("type-catalog schema_version=%q, find-next-instance requires \"1.1\"", w.SchemaVersion)
	}
	var rows []diffmatch.TypeRow
	if err := json.Unmarshal(w.Entries, &rows); err != nil {
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
// shape == "pair" only when both left and right have catalog-shaped members.
// shape == "metric" otherwise; the JSONL emitter checks this invariant.
type outRow struct {
	ClusterID        string                 `json:"cluster_id"`
	Query            string                 `json:"query"`
	Shape            string                 `json:"shape"`
	MatchKind        string                 `json:"match_kind"`
	MatchScore       float64                `json:"match_score,omitempty"`
	Left             map[string]interface{} `json:"left,omitempty"`
	Right            map[string]interface{} `json:"right,omitempty"`
	PRNumber         int                    `json:"pr_number,omitempty"`
	PRRepo           string                 `json:"pr_repo,omitempty"`
	PRHunkOldStart   int                    `json:"pr_hunk_old_start,omitempty"`
	PRHunkOldLines   int                    `json:"pr_hunk_old_lines,omitempty"`
	Intersection     int                    `json:"intersection,omitempty"`
	Union            int                    `json:"union,omitempty"`
	RemovedLineCount int                    `json:"removed_line_count,omitempty"`
	SourceFile       string                 `json:"source_file,omitempty"`
	Notes            string                 `json:"notes,omitempty"`
}

func classifyAndMatch(
	files []diffparse.FileDiff,
	pr int, repo string,
	kindRestriction string,
	minMatchLines int, minJaccard float64,
	fnRows []diffmatch.FunctionRow,
	tyRows []diffmatch.TypeRow,
	fnByLoc map[string][]diffmatch.FunctionRow,
	tyByLoc map[string][]diffmatch.TypeRow,
) []outRow {
	var out []outRow
	for _, f := range files {
		for _, h := range f.Hunks {
			source := f.Path()
			// function-body
			if kindRestriction == "all" || kindRestriction == "function-body" {
				removedNorm := diffmatch.Normalize(h.Removed)
				if len(removedNorm) >= minMatchLines {
					srcFn := enclosingFunction(fnByLoc, source, h.OldStart)
					matches := diffmatch.FunctionBodyMatches(fnRows, removedNorm, minMatchLines, minJaccard, srcLocFile(srcFn), srcLocLine(srcFn))
					for _, m := range matches {
						out = append(out, buildFunctionRow(pr, repo, source, h, m, srcFn))
					}
				}
			}
			// type-shape
			if kindRestriction == "all" || kindRestriction == "type-shape" {
				names := diffmatch.ExtractRemovedFieldNames(h.Removed)
				if len(names) >= 1 {
					srcTy := enclosingType(tyByLoc, source, h.OldStart)
					matches := diffmatch.TypeShapeMatches(tyRows, names, 1, 0.0, srcLocFileTy(srcTy), srcLocLineTy(srcTy))
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
		if out[i].MatchScore != out[j].MatchScore {
			return out[i].MatchScore > out[j].MatchScore
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

// enclosingFunction finds the function-catalog row whose declaration line is
// the latest in `file` not after `lineInFile`. Returns nil when nothing fits.
func enclosingFunction(idx map[string][]diffmatch.FunctionRow, file string, lineInFile int) *diffmatch.FunctionRow {
	rows := idx[file]
	if len(rows) == 0 {
		return nil
	}
	// rows sorted ascending by Line.
	var best *diffmatch.FunctionRow
	for i := range rows {
		if rows[i].Line > lineInFile {
			break
		}
		best = &rows[i]
	}
	return best
}

func enclosingType(idx map[string][]diffmatch.TypeRow, file string, lineInFile int) *diffmatch.TypeRow {
	rows := idx[file]
	if len(rows) == 0 {
		return nil
	}
	var best *diffmatch.TypeRow
	for i := range rows {
		if rows[i].Line > lineInFile {
			break
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
		MatchScore:       m.Jaccard,
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
	if srcFn != nil {
		row.Shape = "pair"
		row.Left = memberFromFunctionRow(*srcFn)
		row.Right = right
		row.ClusterID = "find-next-instance:" + loc(*srcFn) + "__" + loc(m.Row)
	} else {
		row.Shape = "metric"
		row.Right = right // for text-rendering convenience; JSONL drops it because we don't emit `right` on shape:metric (see emit())
		row.Notes = "PR-source location not resolved to a function-catalog entry; emitted as metric per docs/pipeline-contract.md"
		row.ClusterID = "find-next-instance:" + source + ":" + iToA(h.OldStart) + "__" + loc(m.Row)
	}
	return row
}

func buildTypeRow(pr int, repo, source string, h diffparse.Hunk, m diffmatch.TypeShapeMatch, srcTy *diffmatch.TypeRow, removedFields []string) outRow {
	row := outRow{
		Query:            "find-next-instance",
		MatchKind:        "type-shape",
		MatchScore:       m.Jaccard,
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
	if srcTy != nil {
		row.Shape = "pair"
		row.Left = memberFromTypeRow(*srcTy)
		row.Right = right
		row.ClusterID = "find-next-instance:" + locTy(*srcTy) + "__" + locTy(m.Row)
	} else {
		row.Shape = "metric"
		row.Right = right
		row.Notes = "PR-source location not resolved to a type-catalog entry; emitted as metric per docs/pipeline-contract.md"
		row.ClusterID = "find-next-instance:" + source + ":" + iToA(h.OldStart) + "__" + locTy(m.Row)
	}
	return row
}

func memberFromFunctionRow(r diffmatch.FunctionRow) map[string]interface{} {
	return map[string]interface{}{
		"name":    r.Name,
		"kind":    r.Kind,
		"package": r.Package,
		"file":    r.File,
		"line":    r.Line,
	}
}

func memberFromTypeRow(r diffmatch.TypeRow) map[string]interface{} {
	return map[string]interface{}{
		"name":    r.Name,
		"kind":    r.Kind,
		"package": r.Package,
		"file":    r.File,
		"line":    r.Line,
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
		enc := json.NewEncoder(out)
		enc.SetEscapeHTML(false)
		for _, r := range rows {
			// Invariant: pair rows have catalog-shaped left+right. Anything
			// missing demotes to metric here so the renderer can't panic on
			// a nil left.
			if r.Shape == "pair" {
				if r.Left == nil || r.Right == nil {
					r.Shape = "metric"
				}
			}
			// Metric rows MUST NOT carry left/right (they would confuse a
			// pair-shape renderer). We clear them here, after the demotion
			// check above.
			if r.Shape == "metric" {
				r.Left = nil
				r.Right = nil
			}
			if err := enc.Encode(r); err != nil {
				fmt.Fprintf(out, "audit: encode row: %v\n", err)
				return 1
			}
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
		fmt.Fprintf(out, "\n[%s] %d%%  ", r.MatchKind, int(r.MatchScore*100))
		if r.Right != nil {
			fmt.Fprintf(out, "%s:%s:%v:%s\n",
				r.Right["package"], r.Right["file"], r.Right["line"], r.Right["name"])
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
