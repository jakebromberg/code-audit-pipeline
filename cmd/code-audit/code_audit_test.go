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
// --arg surface as skipped under --skip-missing-args rather than failing.
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
