package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jakebromberg/code-audit-pipeline/internal/cli"
)

// TestEmbeddedQueriesPresent confirms `go generate` has populated the
// queries/ subdirectory, the canonical library is reachable, and the count
// matches the pipeline source.
func TestEmbeddedQueriesPresent(t *testing.T) {
	embedded := embeddedQueries()
	if _, err := fs.Stat(embedded, "_canonical.jq"); err != nil {
		t.Fatalf("_canonical.jq missing from embedded FS — did you run `go generate ./...`?: %v", err)
	}
	entries, err := fs.ReadDir(embedded, ".")
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".jq") {
			count++
		}
	}
	if count < 28 {
		t.Errorf("embedded FS has %d .jq files; expected at least 28 (27 queries + _canonical)", count)
	}
}

// TestE2EFileHashes runs the file-hashes extractor + a query end-to-end
// against a synthetic three-file tree. file-hashes uses Node stdlib only —
// no npm install required, so this test runs without integration-build tag.
func TestE2EFileHashes(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not on PATH")
	}
	if _, err := os.Stat("../../extractors/file-hashes/manifest.toml"); err != nil {
		t.Skip("file-hashes extractor not present")
	}

	tmp := t.TempDir()
	repo := filepath.Join(tmp, "repo")
	src := filepath.Join(repo, "src")
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"a.ts": "export const x = 1;\n",
		"b.ts": "export const x = 1;\n", // duplicate of a
		"c.ts": "export const y = 2;\n",
	} {
		if err := os.WriteFile(filepath.Join(src, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Resolve the in-repo extractors directory to point the binary at it.
	extractorsAbs, err := filepath.Abs("../../extractors")
	if err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exitCode := cli.Extract(context.Background(), []string{
		"file-hashes",
		"--root", repo,
		"--audit-root", tmp,
		"--extractors-dir", extractorsAbs,
	}, &out, nil)
	if exitCode != 0 {
		t.Fatalf("Extract exit=%d, out=%s", exitCode, out.String())
	}

	// meta.json should list the catalog.
	metaPath := filepath.Join(tmp, ".audit", "meta.json")
	metaData, err := os.ReadFile(metaPath)
	if err != nil {
		t.Fatalf("read meta: %v", err)
	}
	var meta struct {
		Catalogs map[string]any `json:"catalogs"`
	}
	if err := json.Unmarshal(metaData, &meta); err != nil {
		t.Fatal(err)
	}
	if _, ok := meta.Catalogs["file-hashes"]; !ok {
		t.Errorf("meta.json catalogs missing file-hashes: %v", meta.Catalogs)
	}

	// Query: file-duplicates should find a.ts ↔ b.ts.
	var qout bytes.Buffer
	exitCode = cli.Query(context.Background(), []string{
		"file-duplicates",
		"--root", tmp,
		"--format", "jsonl",
	}, &qout, embeddedQueries())
	if exitCode != 0 {
		t.Fatalf("Query exit=%d, out=%s", exitCode, qout.String())
	}
	if !strings.Contains(qout.String(), "file-duplicates-exact") {
		t.Errorf("expected file-duplicates-exact cluster, got: %s", qout.String())
	}

	// Status: should report file-hashes cached, exit non-zero because
	// extractors source is unresolved in this temp-dir setup (no
	// cwd-relative extractors/ and no AUDIT_HOME).
	var sout bytes.Buffer
	exitCode = cli.Status([]string{
		"--root", tmp,
	}, &sout, embeddedQueries())
	if !strings.Contains(sout.String(), "file-hashes") {
		t.Errorf("status missing file-hashes: %s", sout.String())
	}
	if exitCode == 0 {
		t.Log("status exit=0 (unexpected but tolerable — only diagnostic)")
	}
}

// TestE2EFileHashesScanHeader exercises the --scan-header flag added for
// the copied-from-header.jq query (#220). Runs file-hashes against a tree
// of three files (one with a "Copied from" header, one without, one without
// any flag set as a control) and asserts the catalog rows carry the
// expected header_match shape.
func TestE2EFileHashesScanHeader(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not on PATH")
	}
	if _, err := os.Stat("../../extractors/file-hashes/manifest.toml"); err != nil {
		t.Skip("file-hashes extractor not present")
	}

	tmp := t.TempDir()
	repo := filepath.Join(tmp, "repo")
	src := filepath.Join(repo, "src")
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"forked.ts": "// Copied from DebugPanel for shader testing.\nexport const x = 1;\n",
		"plain.ts":  "import { y } from './y';\nexport const z = 2;\n",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(src, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	extractorsAbs, err := filepath.Abs("../../extractors")
	if err != nil {
		t.Fatal(err)
	}

	// --- Variant 1: with --scan-header set. Every row carries header_match (null or object).
	var out bytes.Buffer
	exitCode := cli.Extract(context.Background(), []string{
		"file-hashes",
		"--root", repo,
		"--audit-root", tmp,
		"--extractors-dir", extractorsAbs,
		"--scan-header",
	}, &out, nil)
	if exitCode != 0 {
		t.Fatalf("Extract (--scan-header) exit=%d, out=%s", exitCode, out.String())
	}

	catalogPath := filepath.Join(tmp, ".audit", "catalogs", "file-hashes.json")
	data, err := os.ReadFile(catalogPath)
	if err != nil {
		t.Fatalf("read catalog: %v", err)
	}
	var rows []map[string]any
	if err := json.Unmarshal(data, &rows); err != nil {
		t.Fatalf("unmarshal catalog: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows in catalog, got %d: %s", len(rows), string(data))
	}
	byFile := map[string]map[string]any{}
	for _, r := range rows {
		f, _ := r["file"].(string)
		byFile[f] = r
	}

	forked := byFile["src/forked.ts"]
	if forked == nil {
		t.Fatalf("missing src/forked.ts row in catalog: %s", string(data))
	}
	hmRaw, ok := forked["header_match"]
	if !ok {
		t.Fatalf("src/forked.ts row missing header_match key (got: %+v)", forked)
	}
	hm, ok := hmRaw.(map[string]any)
	if !ok || hm == nil {
		t.Fatalf("src/forked.ts header_match expected object, got %T: %v", hmRaw, hmRaw)
	}
	if got, _ := hm["phrase"].(string); got != "copied from" {
		t.Errorf("src/forked.ts header_match.phrase = %q, want \"copied from\"", got)
	}
	if got, _ := hm["line"].(float64); int(got) != 1 {
		t.Errorf("src/forked.ts header_match.line = %v, want 1", hm["line"])
	}
	if got, _ := hm["text"].(string); !strings.Contains(got, "Copied from DebugPanel") {
		t.Errorf("src/forked.ts header_match.text = %q, want it to contain \"Copied from DebugPanel\"", got)
	}

	plain := byFile["src/plain.ts"]
	if plain == nil {
		t.Fatalf("missing src/plain.ts row in catalog: %s", string(data))
	}
	plainHM, present := plain["header_match"]
	if !present {
		t.Errorf("src/plain.ts row missing header_match key — with --scan-header set, key must be present (null)")
	}
	if plainHM != nil {
		t.Errorf("src/plain.ts header_match = %v, want nil", plainHM)
	}

	// --- Variant 2: without --scan-header. Field is omitted entirely.
	if err := os.RemoveAll(filepath.Join(tmp, ".audit")); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	exitCode = cli.Extract(context.Background(), []string{
		"file-hashes",
		"--root", repo,
		"--audit-root", tmp,
		"--extractors-dir", extractorsAbs,
	}, &out, nil)
	if exitCode != 0 {
		t.Fatalf("Extract (default) exit=%d, out=%s", exitCode, out.String())
	}
	data, err = os.ReadFile(catalogPath)
	if err != nil {
		t.Fatalf("read catalog v2: %v", err)
	}
	var rows2 []map[string]any
	if err := json.Unmarshal(data, &rows2); err != nil {
		t.Fatalf("unmarshal catalog v2: %v", err)
	}
	for _, r := range rows2 {
		if _, present := r["header_match"]; present {
			t.Errorf("default invocation row %v should NOT carry header_match", r["file"])
		}
	}
}

// TestE2EReport runs `code-audit report` end-to-end against a manually-seeded
// .audit/ cache: catalog file on disk + meta.json index. Asserts the output
// is created, contains the targeted section, and lists skipped queries.
func TestE2EReport(t *testing.T) {
	tmp := t.TempDir()
	cacheDir := filepath.Join(tmp, ".audit", "catalogs")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	catalogPath := filepath.Join(cacheDir, "type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"language":"x","name":"type-catalog","version":"0"},"entries":[
  {"name":"A","kind":"interface","package":"main","file":"a.ts","line":1,"exported":true,"is_test":false,"fields":["id:number"],"shape_sig":"id:number","extends":[],"references":[],"references_count":0,"touched_in_window":false},
  {"name":"B","kind":"interface","package":"main","file":"b.ts","line":1,"exported":true,"is_test":false,"fields":["id:number"],"shape_sig":"id:number","extends":[],"references":[],"references_count":0,"touched_in_window":false}
]}`
	if err := os.WriteFile(catalogPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	// Seed meta.json via the auditdir helper so envelope_summary and
	// source_sha get populated normally.
	var seedOut bytes.Buffer
	exit := cli.Query(context.Background(), []string{
		"exact-duplicates",
		"--root", tmp,
		"--catalog", catalogPath,
		"--format", "jsonl",
	}, &seedOut, embeddedQueries())
	if exit != 0 {
		t.Fatalf("seed Query exit=%d, out=%s", exit, seedOut.String())
	}

	// Place the catalog under the cwd-rooted cache by re-running an Extract
	// here would require a real extractor; instead, seed meta.json by hand.
	metaPath := filepath.Join(tmp, ".audit", "meta.json")
	meta := map[string]any{
		"audit_version":   cli.Version,
		"last_touched_at": "2026-05-30T00:00:00Z",
		"root":            tmp,
		"catalogs": map[string]any{
			"type-catalog": map[string]any{
				"path":       "catalogs/type-catalog.json",
				"source_sha": "seed",
				"cli_args":   map[string]any{},
			},
		},
	}
	mdata, _ := json.MarshalIndent(meta, "", "  ")
	if err := os.WriteFile(metaPath, mdata, 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit = cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "exact-duplicates",
	}, &out, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d, out=%s", exit, out.String())
	}

	matches, err := filepath.Glob(filepath.Join(tmp, ".audit", "reports", "findings-*.md"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected one findings-*.md, got %d", len(matches))
	}
	data, err := os.ReadFile(matches[0])
	if err != nil {
		t.Fatal(err)
	}
	report := string(data)
	for _, want := range []string{
		"# Audit findings",
		"## exact-duplicates",
		"### exact-duplicates:A+B",
	} {
		if !strings.Contains(report, want) {
			t.Errorf("report missing %q\nfull:\n%s", want, report)
		}
	}
}

// TestReportSkipsTwoOfSameKindQueries ensures cross-catalog queries that
// declare the same catalog kind twice (e.g. cross-catalog-name-collisions)
// land in the "Skipped queries" section instead of failing the report. The
// report driver doesn't synthesize the two --catalog overrides those queries
// need; users wanting that query run it via `code-audit query --catalog A
// --catalog B` directly.
func TestReportSkipsTwoOfSameKindQueries(t *testing.T) {
	tmp := t.TempDir()
	cacheDir := filepath.Join(tmp, ".audit", "catalogs")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	catalogPath := filepath.Join(cacheDir, "type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"language":"x","name":"type-catalog","version":"0"},"entries":[]}`
	if err := os.WriteFile(catalogPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(tmp, ".audit", "meta.json")
	meta := map[string]any{
		"audit_version": cli.Version,
		"root":          tmp,
		"catalogs": map[string]any{
			"type-catalog": map[string]any{
				"path":       "catalogs/type-catalog.json",
				"source_sha": "seed",
				"cli_args":   map[string]any{},
			},
		},
	}
	mdata, _ := json.MarshalIndent(meta, "", "  ")
	if err := os.WriteFile(metaPath, mdata, 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "cross-catalog-name-collisions",
	}, &out, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d (want 0; two-of-same-kind should skip not fail), out=%s", exit, out.String())
	}
	matches, err := filepath.Glob(filepath.Join(tmp, ".audit", "reports", "findings-*.md"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("expected one findings-*.md, got %d (err=%v)", len(matches), err)
	}
	data, _ := os.ReadFile(matches[0])
	report := string(data)
	if !strings.Contains(report, "cross-catalog-name-collisions") {
		t.Errorf("report should list cross-catalog-name-collisions as skipped:\n%s", report)
	}
	if !strings.Contains(report, "two-of-same-kind") {
		t.Errorf("skip reason should mention two-of-same-kind:\n%s", report)
	}
}

// TestReportSkipsQueriesWithUnsatisfiedArgs ensures queries with required
// --arg surface as skipped when --skip-missing-args is true. As of #251
// that is the default for text mode; the explicit flag here pins down
// that an explicit `--skip-missing-args` (i.e. `=true`) still works for
// callers that prefer to spell the intent out. See
// TestReportDefaultsToSkippingMissingArgs for the no-flag regression
// guard covering the new default.
func TestReportSkipsQueriesWithUnsatisfiedArgs(t *testing.T) {
	tmp := t.TempDir()
	cacheDir := filepath.Join(tmp, ".audit", "catalogs")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	catalogPath := filepath.Join(cacheDir, "type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"language":"x","name":"type-catalog","version":"0"},"entries":[]}`
	if err := os.WriteFile(catalogPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(tmp, ".audit", "meta.json")
	meta := map[string]any{
		"audit_version": cli.Version,
		"root":          tmp,
		"catalogs": map[string]any{
			"type-catalog": map[string]any{
				"path":       "catalogs/type-catalog.json",
				"source_sha": "seed",
				"cli_args":   map[string]any{},
			},
		},
	}
	mdata, _ := json.MarshalIndent(meta, "", "  ")
	if err := os.WriteFile(metaPath, mdata, 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "near-duplicates",
		"--skip-missing-args",
	}, &out, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d, out=%s", exit, out.String())
	}
	matches, err := filepath.Glob(filepath.Join(tmp, ".audit", "reports", "findings-*.md"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected one findings-*.md, got %d", len(matches))
	}
	data, _ := os.ReadFile(matches[0])
	if !strings.Contains(string(data), "Skipped queries") {
		t.Errorf("report missing skipped section:\n%s", string(data))
	}
	if !strings.Contains(string(data), "near-duplicates") {
		t.Errorf("report should list near-duplicates as skipped:\n%s", string(data))
	}
}

// TestReportDefaultsToSkippingMissingArgs is the regression guard for #251:
// `code-audit report` without --skip-missing-args (i.e. relying on the new
// default of true) must still produce .audit/reports/findings-<date>.md
// and exit 0 when a selected query has unsatisfied required --arg
// front-matter. The bug was that the historical loud-failure default
// caused a fresh `code-audit extract` + `code-audit report` to exit 1
// and write nothing to disk.
func TestReportDefaultsToSkippingMissingArgs(t *testing.T) {
	tmp := t.TempDir()
	cacheDir := filepath.Join(tmp, ".audit", "catalogs")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	catalogPath := filepath.Join(cacheDir, "type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"language":"x","name":"type-catalog","version":"0"},"entries":[]}`
	if err := os.WriteFile(catalogPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(tmp, ".audit", "meta.json")
	meta := map[string]any{
		"audit_version": cli.Version,
		"root":          tmp,
		"catalogs": map[string]any{
			"type-catalog": map[string]any{
				"path":       "catalogs/type-catalog.json",
				"source_sha": "seed",
				"cli_args":   map[string]any{},
			},
		},
	}
	mdata, _ := json.MarshalIndent(meta, "", "  ")
	if err := os.WriteFile(metaPath, mdata, 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	// Note: no --skip-missing-args flag. The new default is true, so this
	// must exit 0 and write findings-<date>.md to disk.
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "near-duplicates",
	}, &out, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d (want 0; default --skip-missing-args should skip not fail), out=%s", exit, out.String())
	}
	matches, err := filepath.Glob(filepath.Join(tmp, ".audit", "reports", "findings-*.md"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected one findings-*.md, got %d", len(matches))
	}
	data, _ := os.ReadFile(matches[0])
	if !strings.Contains(string(data), "Skipped queries") {
		t.Errorf("report missing skipped section:\n%s", string(data))
	}
	if !strings.Contains(string(data), "near-duplicates") {
		t.Errorf("report should list near-duplicates as skipped:\n%s", string(data))
	}
}

// TestReportLoudFailsOnMissingArgsWhenOptOut is the CI-gating regression
// guard: callers that pass --skip-missing-args=false (the pre-#251
// default behavior) must still get a non-zero exit when a query has
// unsatisfied required --arg front-matter. This pins the opt-out path
// so a future refactor that removes the flag entirely is caught.
func TestReportLoudFailsOnMissingArgsWhenOptOut(t *testing.T) {
	tmp := t.TempDir()
	cacheDir := filepath.Join(tmp, ".audit", "catalogs")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	catalogPath := filepath.Join(cacheDir, "type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"language":"x","name":"type-catalog","version":"0"},"entries":[]}`
	if err := os.WriteFile(catalogPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(tmp, ".audit", "meta.json")
	meta := map[string]any{
		"audit_version": cli.Version,
		"root":          tmp,
		"catalogs": map[string]any{
			"type-catalog": map[string]any{
				"path":       "catalogs/type-catalog.json",
				"source_sha": "seed",
				"cli_args":   map[string]any{},
			},
		},
	}
	mdata, _ := json.MarshalIndent(meta, "", "  ")
	if err := os.WriteFile(metaPath, mdata, 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "near-duplicates",
		"--skip-missing-args=false",
	}, &out, embeddedQueries())
	if exit != 1 {
		t.Fatalf("Report exit=%d (want 1; --skip-missing-args=false should loud-fail on missing required --arg), out=%s", exit, out.String())
	}
	// Loud-fail path emits the partial report to stdout and skips the
	// writeAtomic call, so .audit/reports/ should NOT contain a file.
	matches, _ := filepath.Glob(filepath.Join(tmp, ".audit", "reports", "findings-*.md"))
	if len(matches) != 0 {
		t.Errorf("expected no findings-*.md on loud-fail; got %d", len(matches))
	}
}

// seedPRCommentFixture sets up a tmp .audit/ cache with two duplicate type
// entries (A in a.ts, B in b.ts) plus meta.json. Returns the tmp dir.
// Used by TestE2EReportPRComment_* to exercise the --mode pr-comment path.
func seedPRCommentFixture(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	cacheDir := filepath.Join(tmp, ".audit", "catalogs")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	catalogPath := filepath.Join(cacheDir, "type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"language":"x","name":"type-catalog","version":"0"},"entries":[
  {"name":"A","kind":"interface","package":"main","file":"a.ts","line":1,"exported":true,"is_test":false,"fields":["id:number"],"shape_sig":"id:number","extends":[],"references":[],"references_count":0,"touched_in_window":false},
  {"name":"B","kind":"interface","package":"main","file":"b.ts","line":1,"exported":true,"is_test":false,"fields":["id:number"],"shape_sig":"id:number","extends":[],"references":[],"references_count":0,"touched_in_window":false}
]}`
	if err := os.WriteFile(catalogPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(tmp, ".audit", "meta.json")
	meta := map[string]any{
		"audit_version":   cli.Version,
		"last_touched_at": "2026-05-30T00:00:00Z",
		"root":            tmp,
		"catalogs": map[string]any{
			"type-catalog": map[string]any{
				"path":       "catalogs/type-catalog.json",
				"source_sha": "seed",
				"cli_args":   map[string]any{},
			},
		},
	}
	mdata, _ := json.MarshalIndent(meta, "", "  ")
	if err := os.WriteFile(metaPath, mdata, 0o644); err != nil {
		t.Fatal(err)
	}
	return tmp
}

// TestE2EReportPRComment_TouchedFileMatchesCluster — when touched.json
// contains a file that's a member of an exact-duplicate cluster, the
// cluster surfaces in the pr-comment body.
func TestE2EReportPRComment_TouchedFileMatchesCluster(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	touchedPath := filepath.Join(tmp, "touched.json")
	if err := os.WriteFile(touchedPath, []byte(`["a.ts"]`), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(tmp, "comment.md")
	var stdout bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "exact-duplicates",
		"--touched", touchedPath,
		"--mode", "pr-comment",
		"--output", out,
		"--marker", "code-audit-pipeline-v1",
	}, &stdout, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d, stdout=%s", exit, stdout.String())
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	body := string(data)
	if !strings.HasPrefix(body, "<!-- code-audit-pipeline-v1 -->\n") {
		t.Errorf("body should start with sticky marker; got: %q", body[:min(80, len(body))])
	}
	if !strings.Contains(body, "exact-duplicates:A+B") {
		t.Errorf("cluster missing from body:\n%s", body)
	}
	if strings.Contains(body, "Skipped queries") {
		t.Errorf("pr-comment mode should not emit Skipped queries:\n%s", body)
	}
}

// TestE2EReportPRComment_NoTouchedFileMatch — when touched.json contains
// no files that match any cluster member, the body is the no-impact
// notice (still with marker, so the sticky comment updates).
func TestE2EReportPRComment_NoTouchedFileMatch(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	touchedPath := filepath.Join(tmp, "touched.json")
	if err := os.WriteFile(touchedPath, []byte(`["unrelated.ts"]`), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(tmp, "comment.md")
	var stdout bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "exact-duplicates",
		"--touched", touchedPath,
		"--mode", "pr-comment",
		"--output", out,
	}, &stdout, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d, stdout=%s", exit, stdout.String())
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	body := string(data)
	if !strings.HasPrefix(body, "<!-- code-audit-pipeline-v1 -->\n") {
		t.Errorf("marker missing; got: %q", body[:min(80, len(body))])
	}
	if !strings.Contains(body, "No structural impact") {
		t.Errorf("expected no-impact body; got:\n%s", body)
	}
}

// TestE2EReportPRComment_BadTouchedPath — caller-input error (--touched
// points at a missing file) exits 2 loud, NOT fail-quiet. The workflow
// author must fix the input, so we don't silently degrade the comment.
func TestE2EReportPRComment_BadTouchedPath(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	var stdout bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "exact-duplicates",
		"--touched", filepath.Join(tmp, "does-not-exist.json"),
		"--mode", "pr-comment",
	}, &stdout, embeddedQueries())
	if exit != 2 {
		t.Errorf("bad --touched should exit 2 (caller error); got exit=%d, stdout=%s", exit, stdout.String())
	}
	// Caller-input error must NOT pollute stdout — otherwise a workflow
	// piping stdout into the PR comment body would post the error text
	// without a sticky marker.
	if stdout.Len() != 0 {
		t.Errorf("caller-input error should not write to stdout; got: %q", stdout.String())
	}
}

// TestE2EReportPRComment_PrCommentOnlyFlagsInTextMode — passing
// --touched / --marker / --size-cap-bytes / --on-extraction-failure /
// --detected-languages without --mode pr-comment must exit 2 with a usage
// error rather than silently filtering the text-mode report or ignoring
// the flag.
func TestE2EReportPRComment_PrCommentOnlyFlagsInTextMode(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	touchedPath := filepath.Join(tmp, "touched.json")
	if err := os.WriteFile(touchedPath, []byte(`[]`), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		args []string
	}{
		{"touched", []string{"--touched", touchedPath}},
		{"marker", []string{"--marker", "custom"}},
		{"size-cap-bytes", []string{"--size-cap-bytes", "30000"}},
		{"on-extraction-failure", []string{"--on-extraction-failure", "loud"}},
		{"detected-languages", []string{"--detected-languages", "typescript"}},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			args := append([]string{"--root", tmp, "--query", "exact-duplicates"}, c.args...)
			var stdout bytes.Buffer
			exit := cli.Report(context.Background(), args, &stdout, embeddedQueries())
			if exit != 2 {
				t.Errorf("--%s in text mode should exit 2; got exit=%d", c.name, exit)
			}
		})
	}
}

// TestE2EReportPRComment_InvalidMarker — markers containing characters
// that would corrupt the sticky-comment scan (-->, newline, space, etc.)
// are rejected at flag-parse time. Includes iteration-3 constraints
// (leading non-alphanumeric, adjacent `--`, length cap) to pin the
// binary contract at the flag boundary in addition to the unit test.
func TestE2EReportPRComment_InvalidMarker(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	cases := []string{
		"",               // empty
		"has space",      // whitespace
		"contains-->bad", // closes HTML comment early
		"line\nbreak",    // multi-line
		"angle<bracket>", // < / >
		// iteration-3 additions:
		"-leading-dash",          // leading non-alphanumeric (HTML5 bogus-comment risk)
		"_leading-underscore",    // leading non-alphanumeric
		"/leading-slash",         // leading non-alphanumeric
		"foo--bar",               // adjacent `--` (HTML5 forbids inside <!-- -->)
		strings.Repeat("a", 129), // exceeds markerMaxLen (128 bytes)
		"with\tab",               // embedded tab (control char)
		"with\rcr",               // embedded CR
	}
	for _, marker := range cases {
		marker := marker
		t.Run(marker, func(t *testing.T) {
			var stdout bytes.Buffer
			exit := cli.Report(context.Background(), []string{
				"--root", tmp,
				"--query", "exact-duplicates",
				"--mode", "pr-comment",
				"--marker", marker,
			}, &stdout, embeddedQueries())
			if exit != 2 {
				t.Errorf("invalid --marker %q should exit 2; got exit=%d", marker, exit)
			}
		})
	}
}

// TestE2EReportPRComment_SizeCapBelowMin — --size-cap-bytes below
// sizeCapMin (1024) is a caller-input error in pr-comment mode; exits 2
// at the flag boundary so the cap-honoring contract isn't silently
// violated by a typo or accidental small value.
func TestE2EReportPRComment_SizeCapBelowMin(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	for _, cap := range []string{"0", "-1", "100", "1023"} {
		cap := cap
		t.Run(cap, func(t *testing.T) {
			var stdout bytes.Buffer
			exit := cli.Report(context.Background(), []string{
				"--root", tmp,
				"--query", "exact-duplicates",
				"--mode", "pr-comment",
				"--size-cap-bytes", cap,
			}, &stdout, embeddedQueries())
			if exit != 2 {
				t.Errorf("--size-cap-bytes %s should exit 2 (below sizeCapMin); got exit=%d", cap, exit)
			}
		})
	}
}

// TestE2EReportPRComment_DiagnosticsOnStderr — caller-input errors and
// the "wrote …" pointer in pr-comment mode must not appear on the
// caller-supplied stdout writer (which a workflow may pipe into the PR
// comment body).
func TestE2EReportPRComment_DiagnosticsOnStderr(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	touchedPath := filepath.Join(tmp, "touched.json")
	if err := os.WriteFile(touchedPath, []byte(`["a.ts"]`), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(tmp, "comment.md")
	var stdout bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "exact-duplicates",
		"--touched", touchedPath,
		"--mode", "pr-comment",
		"--output", out,
	}, &stdout, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d, stdout=%s", exit, stdout.String())
	}
	if strings.Contains(stdout.String(), "wrote") {
		t.Errorf("pr-comment mode 'wrote …' diagnostic must go to stderr, not stdout; got stdout: %q", stdout.String())
	}
}

// TestE2EReportPRComment_TextModeUnaffected — --mode text (default)
// preserves the existing pre-PR output behavior byte-for-byte. The
// presence of the new flags must not change text-mode behavior.
func TestE2EReportPRComment_TextModeUnaffected(t *testing.T) {
	tmp := seedPRCommentFixture(t)
	var stdout bytes.Buffer
	exit := cli.Report(context.Background(), []string{
		"--root", tmp,
		"--query", "exact-duplicates",
	}, &stdout, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Report exit=%d, stdout=%s", exit, stdout.String())
	}
	matches, err := filepath.Glob(filepath.Join(tmp, ".audit", "reports", "findings-*.md"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("expected one findings-*.md, got matches=%v err=%v", matches, err)
	}
	data, _ := os.ReadFile(matches[0])
	report := string(data)
	if !strings.Contains(report, "# Audit findings") {
		t.Errorf("text-mode header missing; pr-comment changes leaked into text mode:\n%s", report)
	}
	if strings.Contains(report, "<!-- code-audit-pipeline-v1 -->") {
		t.Errorf("sticky marker leaked into text-mode output:\n%s", report)
	}
}

// TestQueryWithExplicitCatalog confirms `code-audit query --catalog <path>` works
// without any cached .audit/ catalog.
func TestQueryWithExplicitCatalog(t *testing.T) {
	tmp := t.TempDir()
	cat := filepath.Join(tmp, "tiny-type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"name":"x"},"entries":[
  {"name":"A","kind":"interface","package":"main","file":"a.ts","line":1,"exported":true,"is_test":false,"fields":["id:number"],"shape_sig":"id:number","extends":[],"references":[],"references_count":0,"touched_in_window":false},
  {"name":"B","kind":"interface","package":"main","file":"b.ts","line":1,"exported":true,"is_test":false,"fields":["id:number"],"shape_sig":"id:number","extends":[],"references":[],"references_count":0,"touched_in_window":false}
]}`
	if err := os.WriteFile(cat, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	exit := cli.Query(context.Background(), []string{
		"exact-duplicates",
		"--root", tmp,
		"--catalog", cat,
		"--format", "jsonl",
	}, &out, embeddedQueries())
	if exit != 0 {
		t.Fatalf("Query exit=%d, out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "exact-duplicates:A+B") {
		t.Errorf("expected cluster_id exact-duplicates:A+B; got: %s", out.String())
	}
}
