package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
	"github.com/jakebromberg/code-audit-pipeline/internal/engine"
	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
	"github.com/jakebromberg/code-audit-pipeline/internal/render"
)

// Report implements `code-audit report` — runs every runnable query in JSONL mode,
// dispatches each row to the shape renderer, and writes the result to
// .audit/reports/findings-<date>.md.
//
// With --mode pr-comment, the output is a GitHub PR-comment body keyed by a
// sticky-comment marker on line 1, with cluster-shape rows filtered through
// --touched (a JSON array of repo-relative file paths). Pipeline-internal
// errors fail quiet (exit 0 with a marker body) so the comment surface
// stays current; caller-input errors (bad --touched) exit 2 loud so the
// workflow author fixes the resolve-touched.sh step. See
// docs/pipeline-contract.md §"CLI contract" and docs/plans/123-implementation.md.
func Report(ctx context.Context, argv []string, stdout io.Writer, queriesFS fs.FS) int {
	fset := flag.NewFlagSet("report", flag.ContinueOnError)
	rootFlag := fset.String("root", "", "audit root (defaults to cwd)")
	queriesDir := fset.String("queries-dir", "", "explicit queries directory")
	outputFlag := fset.String("output", "", "destination .md file (default: .audit/reports/findings-YYYY-MM-DD.md)")
	skipMissingArgs := fset.Bool("skip-missing-args", false, "skip queries with unsatisfied required --arg instead of failing")
	touchedFlag := fset.String("touched", "", "path to JSON array of repo-relative paths; filters cluster rows to ones whose members include a touched file")
	modeFlag := fset.String("mode", "text", "output mode: text | pr-comment")
	failureFlag := fset.String("on-extraction-failure", "", "loud | quiet (default: loud for text, quiet for pr-comment)")
	sizeCapFlag := fset.Int("size-cap-bytes", 60000, "max comment body size in pr-comment mode (default 60000, ~4KB headroom under GitHub's 65,536-byte cap)")
	markerFlag := fset.String("marker", "code-audit-pipeline-v1", "sticky-comment marker for --mode pr-comment; emitted as <!-- <marker> --> on line 1")
	detectedLangsFlag := fset.String("detected-languages", "", "comma-separated language list used in the fail-quiet body; the composite forwards audit-core's languages-detected output here")
	var queryFilters, shapeFilters, argFlags, argJSONFlags, envFlags stringList
	fset.Var(&queryFilters, "query", "run only this query (repeatable)")
	fset.Var(&shapeFilters, "shape", "run only queries whose front-matter shape includes this (cluster|pair|metric, repeatable)")
	fset.Var(&argFlags, "arg", "--arg NAME=VALUE forwarded to every query (repeatable)")
	fset.Var(&argJSONFlags, "argjson", "--argjson NAME=JSON forwarded to every query (repeatable)")
	fset.Var(&envFlags, "env", "--env NAME=VALUE forwarded to every query (repeatable)")
	if err := fset.Parse(argv); err != nil {
		return 2
	}

	if *modeFlag != "text" && *modeFlag != "pr-comment" {
		fmt.Fprintf(stdout, "code-audit: --mode must be text or pr-comment, got %q\n", *modeFlag)
		return 2
	}
	failureMode := *failureFlag
	if failureMode == "" {
		if *modeFlag == "pr-comment" {
			failureMode = "quiet"
		} else {
			failureMode = "loud"
		}
	}
	if failureMode != "loud" && failureMode != "quiet" {
		fmt.Fprintf(stdout, "code-audit: --on-extraction-failure must be loud or quiet, got %q\n", failureMode)
		return 2
	}

	var touched touchedSet
	if *touchedFlag != "" {
		t, err := loadTouchedSet(*touchedFlag)
		if err != nil {
			fmt.Fprintf(stdout, "code-audit: %v\n", err)
			return 2
		}
		touched = t
	}

	root := *rootFlag
	if root == "" {
		cwd, _ := os.Getwd()
		root = cwd
	}
	absRoot, _ := filepath.Abs(root)

	qsrc, err := discovery.ResolveQueriesDir(discovery.QueryOpts{
		Flag: *queriesDir, AuditHome: os.Getenv("AUDIT_HOME"), CWD: absRoot,
	}, queriesFS)
	if err != nil {
		fmt.Fprintf(stdout, "code-audit: %v\n", err)
		return 3
	}

	queryNames, err := listQueries(qsrc)
	if err != nil {
		fmt.Fprintf(stdout, "code-audit: list queries: %v\n", err)
		return 3
	}

	queryFilter := toSet(queryFilters)
	shapeFilter := toSet(shapeFilters)

	var results []sectionResult

	for _, name := range queryNames {
		if len(queryFilter) > 0 && !queryFilter[name] {
			continue
		}
		res, skip := runReportQuery(ctx, qsrc, absRoot, name, shapeFilter, argFlags, argJSONFlags, envFlags, *skipMissingArgs, touched)
		if skip {
			continue
		}
		results = append(results, res)
	}

	if *modeFlag == "pr-comment" {
		return emitPRComment(stdout, results, prCommentOpts{
			marker:       *markerFlag,
			sizeCapBytes: *sizeCapFlag,
		}, failureMode, parseCSV(*detectedLangsFlag), *outputFlag)
	}

	report, failed := composeReport(absRoot, results)
	if failed {
		fmt.Fprintln(stdout, report)
		return 1
	}

	dest := *outputFlag
	if dest == "" {
		dest = filepath.Join(absRoot, ".audit", "reports", "findings-"+time.Now().UTC().Format("2006-01-02")+".md")
	}
	if err := writeAtomic(dest, []byte(report)); err != nil {
		fmt.Fprintf(stdout, "code-audit: write report: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "code-audit: wrote %s\n", dest)
	return 0
}

// emitPRComment is the pr-comment-mode finalizer: it applies fail-quiet
// substitution if any section failed, writes the body to --output (or
// stdout when --output is empty), and returns the exit code.
//
// In quiet failure mode, any sectionResult with err != nil collapses the
// entire body to the fail-quiet notice; the loud body is written to
// stderr so it shows up in the runner log. In loud failure mode, errors
// are formatted into the body and the function returns exit code 1.
func emitPRComment(
	stdout io.Writer,
	results []sectionResult,
	opts prCommentOpts,
	failureMode string,
	detectedLanguages []string,
	outputPath string,
) int {
	anyErr := false
	for _, r := range results {
		if r.err != nil {
			anyErr = true
			break
		}
	}

	var body string
	exit := 0
	if anyErr {
		if failureMode == "quiet" {
			// Loud body to stderr for diagnostics; quiet body to comment surface.
			for _, r := range results {
				if r.err != nil {
					fmt.Fprintf(os.Stderr, "code-audit: query %s: %v\n", r.name, r.err)
				}
			}
			body = failQuietBody(opts.marker, detectedLanguages)
		} else {
			body = composePRComment(results, opts)
			exit = 1
		}
	} else {
		body = composePRComment(results, opts)
	}

	if outputPath == "" {
		fmt.Fprint(stdout, body)
		return exit
	}
	if err := writeAtomic(outputPath, []byte(body)); err != nil {
		fmt.Fprintf(os.Stderr, "code-audit: write pr-comment: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "code-audit: wrote %s\n", outputPath)
	return exit
}

// parseCSV splits a comma-separated string; empty input returns nil.
// Whitespace around each entry is trimmed; empty entries are dropped.
func parseCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// runReportQuery executes a single query for the report run and returns its
// sectionResult. The second return is true when the caller should drop the
// query entirely (e.g. _canonical, shape-filtered out) rather than record a
// skipped/error entry. The per-query temp-file cleanup is deferred inside,
// so every exit path — including engine errors — releases resources without
// the call site having to remember.
func runReportQuery(
	ctx context.Context,
	qsrc discovery.Source,
	absRoot string,
	name string,
	shapeFilter map[string]bool,
	argFlags, argJSONFlags, envFlags stringList,
	skipMissingArgs bool,
	touched touchedSet,
) (sectionResult, bool) {
	body, queryFile, cleanup, err := readQuery(qsrc, name)
	if err != nil {
		return sectionResult{name: name, skipped: "could not read: " + err.Error()}, false
	}
	defer cleanup()

	header, err := frontmatter.Parse(strings.NewReader(body))
	if err != nil {
		// _canonical.jq has no front-matter; skip silently. Real
		// queries are required to carry it, so a parse failure on
		// any other file IS a finding.
		if name == "_canonical" {
			return sectionResult{}, true
		}
		return sectionResult{name: name, skipped: "front-matter parse: " + err.Error()}, false
	}
	if len(shapeFilter) > 0 && !shapeIntersects(header.Shape, shapeFilter) {
		return sectionResult{}, true
	}
	if !supportsFormat(header.Formats, "jsonl") {
		return sectionResult{name: name, skipped: "no jsonl format"}, false
	}
	bindings, err := buildBindings(header, argFlags, argJSONFlags)
	if err != nil {
		if skipMissingArgs && strings.Contains(err.Error(), "requires --arg") {
			return sectionResult{name: name, skipped: err.Error()}, false
		}
		return sectionResult{name: name, err: err}, false
	}
	inputPath, slurpfiles, err := wireCatalogs(absRoot, header, nil)
	if err != nil {
		// Three skip-worthy classes: a catalog the query wants isn't cached
		// yet; a two-of-same-kind cross-catalog query that can't run without
		// explicit --catalog overrides the report driver doesn't synthesize
		// (cross-catalog-name-collisions); and unknown catalog kinds the
		// driver has no slurpfile mapping for. All three should land the
		// query in the "Skipped queries" section, not fail the run.
		msg := err.Error()
		if strings.Contains(msg, "not cached") ||
			strings.Contains(msg, "two-of-same-kind") ||
			strings.Contains(msg, "no slurpfile variable mapping") {
			return sectionResult{name: name, skipped: msg}, false
		}
		return sectionResult{name: name, err: err}, false
	}

	env := map[string]string{}
	for _, e := range header.Envs {
		env[e.Name] = e.Default
	}
	for _, kv := range envFlags {
		k, v, ok := splitKV(kv)
		if !ok {
			return sectionResult{name: name, err: fmt.Errorf("--env expects NAME=VALUE, got %q", kv)}, false
		}
		env[k] = v
	}
	env["OUTPUT_FORMAT"] = "jsonl"

	buf := &bytes.Buffer{}
	opts := engine.Opts{
		QuerySource: body,
		InputPath:   inputPath,
		Bindings:    bindings,
		Slurpfiles:  slurpfiles,
		Env:         env,
		Out:         buf,
		Raw:         true,
		UseSystemJQ: header.Engine == "jq",
		QueryFile:   queryFile,
	}
	if qsrc.Path != "" {
		opts.LibDir = qsrc.Path
	} else {
		opts.LibFS = qsrc.FS
	}

	if err := engine.Run(ctx, opts); err != nil {
		return sectionResult{name: name, header: header, err: fmt.Errorf("engine: %w", err)}, false
	}

	rows, err := parseJSONLRows(buf.Bytes())
	if err != nil {
		return sectionResult{name: name, header: header, err: err}, false
	}
	rows = filterRowsByTouched(rows, header, touched)
	blocks, err := renderRows(rows)
	if err != nil {
		return sectionResult{name: name, header: header, err: err}, false
	}
	if len(blocks) == 0 {
		return sectionResult{name: name, skipped: "no rows"}, false
	}
	return sectionResult{name: name, header: header, blocks: blocks}, false
}

// parseJSONLRows parses each non-blank line as a JSON object and returns
// the resulting rows. Split from renderJSONL so the touched-file filter
// can act on rows before shape dispatch.
func parseJSONLRows(buf []byte) ([]render.Row, error) {
	var out []render.Row
	for i, line := range strings.Split(strings.TrimRight(string(buf), "\n"), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		var row render.Row
		if err := json.Unmarshal([]byte(trimmed), &row); err != nil {
			return nil, fmt.Errorf("parse jsonl line %d: %w", i+1, err)
		}
		out = append(out, row)
	}
	return out, nil
}

// renderRows dispatches each row through the shape renderer. Returns one
// markdown block per row.
func renderRows(rows []render.Row) ([]string, error) {
	out := make([]string, 0, len(rows))
	for i, row := range rows {
		md, err := render.Dispatch(row)
		if err != nil {
			return nil, fmt.Errorf("render row %d: %w", i+1, err)
		}
		out = append(out, md)
	}
	return out, nil
}

// sectionResult is the per-query outcome accumulated by Report and consumed
// by composeReport.
type sectionResult struct {
	name    string
	header  *frontmatter.Header
	blocks  []string
	err     error
	skipped string
}

// composeReport assembles the final markdown. The second return is true if
// any query raised an engine-level error; the caller exits non-zero.
func composeReport(absRoot string, results []sectionResult) (string, bool) {
	now := time.Now().UTC().Format(time.RFC3339)
	var b strings.Builder
	fmt.Fprintf(&b, "# Audit findings\n\n")
	fmt.Fprintf(&b, "_Generated %s by code-audit %s. Root: %s._\n\n", now, Version, absRoot)

	var sections []string
	var skipped []string
	failed := false
	for _, r := range results {
		if r.err != nil {
			failed = true
			skipped = append(skipped, fmt.Sprintf("%s — error: %v", r.name, r.err))
			continue
		}
		if r.skipped != "" {
			skipped = append(skipped, fmt.Sprintf("%s — %s", r.name, r.skipped))
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
		sections = append(sections, sec.String())
	}

	if len(sections) == 0 && len(skipped) == 0 {
		b.WriteString("_No findings._\n")
	} else {
		for _, s := range sections {
			b.WriteString(s)
		}
	}
	if len(skipped) > 0 {
		b.WriteString("## Skipped queries\n\n")
		sort.Strings(skipped)
		for _, s := range skipped {
			fmt.Fprintf(&b, "- %s\n", s)
		}
	}
	return b.String(), failed
}

// listQueries enumerates query base names (no extension, no leading
// underscore for library files) from the resolved source.
func listQueries(src discovery.Source) ([]string, error) {
	var names []string
	if src.FS != nil {
		entries, err := fs.ReadDir(src.FS, ".")
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			n := e.Name()
			if !strings.HasSuffix(n, ".jq") {
				continue
			}
			base := strings.TrimSuffix(n, ".jq")
			if strings.HasPrefix(base, "_") {
				continue
			}
			names = append(names, base)
		}
	} else {
		entries, err := os.ReadDir(src.Path)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			n := e.Name()
			if !strings.HasSuffix(n, ".jq") {
				continue
			}
			base := strings.TrimSuffix(n, ".jq")
			if strings.HasPrefix(base, "_") {
				continue
			}
			names = append(names, base)
		}
	}
	sort.Strings(names)
	return names, nil
}

func toSet(xs stringList) map[string]bool {
	if len(xs) == 0 {
		return nil
	}
	out := make(map[string]bool, len(xs))
	for _, x := range xs {
		out[x] = true
	}
	return out
}

func shapeIntersects(declared []string, want map[string]bool) bool {
	for _, s := range declared {
		if want[s] {
			return true
		}
	}
	return false
}

// writeAtomic writes via tmp-then-rename. Creates the parent dir if needed.
func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
