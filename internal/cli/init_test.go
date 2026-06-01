package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// setupSource builds a minimal --from tree: extractors/typescript/manifest.toml
// and pipeline/queries/exact-duplicates.jq. Returns the source root.
func setupSource(t *testing.T) string {
	t.Helper()
	src := t.TempDir()
	mkfile := func(path, body string) {
		full := filepath.Join(src, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mkfile("extractors/typescript/manifest.toml", `schema_version = 1
[extractor]
name = "typescript"
version = "0.0.1"
[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["node", "type-catalog.mjs", "--output", "{output}"]
`)
	mkfile("extractors/typescript/type-catalog.mjs", "// extractor\n")
	mkfile("pipeline/queries/exact-duplicates.jq", "#! query: exact-duplicates\n")
	mkfile("pipeline/queries/_canonical.jq", "# helper\n")
	// node_modules and .git must be skipped:
	mkfile("extractors/typescript/node_modules/foo.js", "skip me\n")
	mkfile(".git/HEAD", "ref: refs/heads/main\n")
	mkfile(".git/refs/heads/main", "deadbeef\n")
	return src
}

func TestInitFreshCopy(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit != 0 {
		t.Fatalf("Init exit=%d, out=%s", exit, out.String())
	}

	for _, rel := range []string{
		"extractors/typescript/manifest.toml",
		"extractors/typescript/type-catalog.mjs",
		"pipeline/queries/exact-duplicates.jq",
		"pipeline/queries/_canonical.jq",
	} {
		if _, err := os.Stat(filepath.Join(dest, rel)); err != nil {
			t.Errorf("missing copied file %s: %v", rel, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dest, "extractors/typescript/node_modules/foo.js")); err == nil {
		t.Errorf("node_modules was not skipped")
	}

	state := readState(t, dest)
	if state.SourceCommitSHA != "deadbeef" {
		t.Errorf("state.source_commit_sha=%q, want deadbeef", state.SourceCommitSHA)
	}
	if _, ok := state.Files["pipeline/queries/exact-duplicates.jq"]; !ok {
		t.Errorf("state.files missing exact-duplicates.jq: %#v", state.Files)
	}
}

func TestInitNoOpOnRerun(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")
	mustInit(t, src, dest)

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit != 0 {
		t.Fatalf("rerun Init exit=%d, out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "0 new, 0 upgraded") {
		t.Errorf("expected no-op summary, got: %s", out.String())
	}
}

func TestInitDirtyWithoutForce(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")
	mustInit(t, src, dest)

	target := filepath.Join(dest, "pipeline/queries/exact-duplicates.jq")
	if err := os.WriteFile(target, []byte("LOCALLY EDITED\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--upgrade"}, &out, nil)
	if exit != 1 {
		t.Fatalf("Init exit=%d (want 1 for dirty), out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "DIRTY") {
		t.Errorf("expected DIRTY warning, got: %s", out.String())
	}
	data, _ := os.ReadFile(target)
	if string(data) != "LOCALLY EDITED\n" {
		t.Errorf("dirty file was overwritten: %q", string(data))
	}
}

func TestInitDirtyWithForce(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")
	mustInit(t, src, dest)

	target := filepath.Join(dest, "pipeline/queries/exact-duplicates.jq")
	if err := os.WriteFile(target, []byte("LOCALLY EDITED\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--force"}, &out, nil)
	if exit != 0 {
		t.Fatalf("--force Init exit=%d, out=%s", exit, out.String())
	}
	data, _ := os.ReadFile(target)
	if !strings.Contains(string(data), "#! query: exact-duplicates") {
		t.Errorf("expected dirty file overwritten, got: %q", string(data))
	}
}

// TestInitReconcilesAfterStateLoss covers the path documented in the plan:
// the state file is deleted between runs (manual setup, or a previous-version
// install). The next run should treat every destination file as NEW, copy in,
// and write a fresh state.
func TestInitReconcilesAfterStateLoss(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")
	mustInit(t, src, dest)

	statePath := filepath.Join(dest, stateFile)
	if err := os.Remove(statePath); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--upgrade"}, &out, nil)
	if exit != 0 {
		t.Fatalf("reconcile Init exit=%d, out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "4 new") {
		t.Errorf("expected 4 NEW after state loss, got: %s", out.String())
	}
	state := readState(t, dest)
	if len(state.Files) != 4 {
		t.Errorf("state should record 4 files post-reconcile, got %d", len(state.Files))
	}
}

// TestInitUpgradePullsNewSrc verifies --upgrade refreshes a CLEAN destination
// when the source file has changed. Without this test, the central
// `code-audit init --upgrade` happy path was only exercised indirectly via the
// dirty / state-loss reconciliation tests.
func TestInitUpgradePullsNewSrc(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")
	mustInit(t, src, dest)

	// Update the source file (pristine sha changes).
	srcFile := filepath.Join(src, "pipeline/queries/exact-duplicates.jq")
	if err := os.WriteFile(srcFile, []byte("#! query: exact-duplicates (v2)\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--upgrade"}, &out, nil)
	if exit != 0 {
		t.Fatalf("upgrade Init exit=%d, out=%s", exit, out.String())
	}
	got, err := os.ReadFile(filepath.Join(dest, "pipeline/queries/exact-duplicates.jq"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "(v2)") {
		t.Errorf("--upgrade did not refresh CLEAN file from new src: %q", string(got))
	}
	if !strings.Contains(out.String(), "upgraded") {
		t.Errorf("expected `upgraded` in summary, got: %s", out.String())
	}
}

// TestInitDryRun verifies --dry-run prints the planned actions and writes
// neither the destination files nor the state file. Covers the path
// classifyFiles → switch{stateNew}: `if *dryRun { ... }`.
func TestInitDryRun(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--dry-run"}, &out, nil)
	if exit != 0 {
		t.Fatalf("dry-run Init exit=%d, out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "would copy NEW") {
		t.Errorf("expected `would copy NEW` lines, got: %s", out.String())
	}
	// Destination must remain empty: no files copied, no state file written.
	if _, err := os.Stat(filepath.Join(dest, "pipeline/queries/exact-duplicates.jq")); err == nil {
		t.Errorf("dry-run wrote a file it shouldn't have")
	}
	if _, err := os.Stat(filepath.Join(dest, stateFile)); err == nil {
		t.Errorf("dry-run wrote a state file it shouldn't have")
	}
}

// TestInitRefusesSymlinkLoop verifies the guard against a dest that is a
// symlink targeting the source (the developer setup ADR-0006 calls out).
func TestInitRefusesSymlinkLoop(t *testing.T) {
	src := setupSource(t)
	destParent := t.TempDir()
	dest := filepath.Join(destParent, "audit-home")
	if err := os.Symlink(src, dest); err != nil {
		t.Skipf("symlink unsupported on this platform: %v", err)
	}

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit == 0 {
		t.Fatalf("expected non-zero exit for symlink loop, got 0; out=%s", out.String())
	}
	if !strings.Contains(out.String(), "refusing to copy into self") {
		t.Errorf("expected `refusing to copy into self`, got: %s", out.String())
	}
}

// TestInitMissingFromFlag exercises the --from-required validation path. The
// init contract is "v1 requires --from"; this nails the error message and
// exit code down so a regression to "default to cwd" doesn't slip through.
func TestInitMissingFromFlag(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--dest", dest}, &out, nil)
	if exit != 2 {
		t.Fatalf("missing --from Init exit=%d (want 2), out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "--from") {
		t.Errorf("expected --from in error, got: %s", out.String())
	}
}

// TestInitPreservesExecutableBit pins down that copyFile inherits the
// source's permission bits. Real extractor/test scripts (e.g.
// extractors/typescript/tests/test_smoke.sh) are 0o755 in the repo; losing
// the exec bit on copy turns `./test_smoke.sh` into "permission denied".
func TestInitPreservesExecutableBit(t *testing.T) {
	src := setupSource(t)
	// Drop an executable script into the source's extractor dir so the walk
	// picks it up.
	exe := filepath.Join(src, "extractors/typescript/tests/test_smoke.sh")
	if err := os.MkdirAll(filepath.Dir(exe), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(exe, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "audit-home")
	mustInit(t, src, dest)

	info, err := os.Stat(filepath.Join(dest, "extractors/typescript/tests/test_smoke.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Errorf("executable bit lost on copy: mode=%v", info.Mode().Perm())
	}
}

func mustInit(t *testing.T, src, dest string) {
	t.Helper()
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit != 0 {
		t.Fatalf("setup Init exit=%d, out=%s", exit, out.String())
	}
}

func readState(t *testing.T, dest string) InitState {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dest, stateFile))
	if err != nil {
		t.Fatal(err)
	}
	var s InitState
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// writeBootstrapManifest replaces the manifest in setupSource's tree with
// one that declares a schema-2 [runtime].bootstrap argv. argv runs from the
// extractor's destination directory.
func writeBootstrapManifest(t *testing.T, src string, bootstrap []string) {
	t.Helper()
	body := `schema_version = 2
[extractor]
name = "typescript"
version = "0.0.1"
[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["node", "type-catalog.mjs", "--output", "{output}"]

[runtime]
bootstrap = [`
	for i, a := range bootstrap {
		if i > 0 {
			body += ", "
		}
		// embed each argv element as a JSON-quoted TOML string
		b, _ := json.Marshal(a)
		body += string(b)
	}
	body += `]
setup_hint = "test setup hint"
`
	if err := os.WriteFile(filepath.Join(src, "extractors/typescript/manifest.toml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// Test 8 — runBootstrap invokes with Cmd.Dir == extractor dir and captures
// stderr on failure.
func TestRunBootstrap_CwdAndStderr(t *testing.T) {
	dir := t.TempDir()
	m := &manifest.Manifest{
		SchemaVersion: manifest.SchemaVersion2,
		Runtime:       manifest.Runtime{Bootstrap: []string{"sh", "-c", "pwd > cwd.txt; echo BOOM >&2; exit 7"}},
	}
	err := runBootstrap(context.Background(), dir, m, nil)
	if err == nil {
		t.Fatal("expected error from exit 7, got nil")
	}
	be, ok := err.(*BootstrapError)
	if !ok {
		t.Fatalf("expected *BootstrapError, got %T", err)
	}
	if !strings.Contains(string(be.Stderr), "BOOM") {
		t.Errorf("stderr should contain BOOM, got %q", string(be.Stderr))
	}
	if be.Exit != 7 {
		t.Errorf("exit = %d, want 7", be.Exit)
	}
	got, err := os.ReadFile(filepath.Join(dir, "cwd.txt"))
	if err != nil {
		t.Fatalf("read cwd.txt: %v", err)
	}
	resolved, _ := filepath.EvalSymlinks(dir)
	pwd := strings.TrimSpace(string(got))
	if pwd != resolved && pwd != dir {
		t.Errorf("cwd = %q, want %q (or %q)", pwd, dir, resolved)
	}
}

// Test 8a — runBootstrap truncates captured stderr at the 64KB cap.
func TestRunBootstrap_StderrCap(t *testing.T) {
	dir := t.TempDir()
	// Emit 200KB on stderr then exit 1 — well over the 64KB cap.
	m := &manifest.Manifest{
		SchemaVersion: manifest.SchemaVersion2,
		Runtime:       manifest.Runtime{Bootstrap: []string{"sh", "-c", "head -c 204800 /dev/zero | tr '\\0' 'X' >&2; exit 1"}},
	}
	err := runBootstrap(context.Background(), dir, m, nil)
	be, ok := err.(*BootstrapError)
	if !ok {
		t.Fatalf("expected *BootstrapError, got %T", err)
	}
	if len(be.Stderr) > bootstrapStderrCap {
		t.Errorf("stderr len = %d, want <= %d", len(be.Stderr), bootstrapStderrCap)
	}
	if len(be.Stderr) < bootstrapStderrCap-1024 {
		t.Errorf("stderr len = %d, want close to %d", len(be.Stderr), bootstrapStderrCap)
	}
}

// Test 8b — runBootstrap respects context cancellation and preserves both
// the underlying cmd.Run error AND ctx.Err via errors.Join.
func TestRunBootstrap_ContextCancellation(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel) // belt-and-suspenders if the test exits early
	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()
	m := &manifest.Manifest{
		SchemaVersion: manifest.SchemaVersion2,
		Runtime:       manifest.Runtime{Bootstrap: []string{"sh", "-c", "sleep 30"}},
	}
	start := time.Now()
	err := runBootstrap(ctx, dir, m, nil)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("expected cancellation error, got nil")
	}
	if elapsed > 5*time.Second {
		t.Errorf("runBootstrap did not return promptly under ctx cancel: %v", elapsed)
	}
	// Cause chain must surface ctx.Err so callers using errors.Is can
	// distinguish cancellation from exec failure.
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err chain should match context.Canceled; got %v", err)
	}
	// And the original exec.ExitError (signal-killed) must remain
	// reachable via errors.As so callers can probe the signal.
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		t.Errorf("err chain should preserve *exec.ExitError; got %v", err)
	}
}

// Test 8c — runBootstrap on a missing binary (ENOENT) reports exit
// bootstrapNoExitCode (-1) instead of misleading exit 0.
func TestRunBootstrap_MissingBinary(t *testing.T) {
	dir := t.TempDir()
	m := &manifest.Manifest{
		SchemaVersion: manifest.SchemaVersion2,
		Runtime:       manifest.Runtime{Bootstrap: []string{"this-binary-definitely-does-not-exist-9b3a"}},
	}
	err := runBootstrap(context.Background(), dir, m, nil)
	if err == nil {
		t.Fatal("expected exec lookup error, got nil")
	}
	be, ok := err.(*BootstrapError)
	if !ok {
		t.Fatalf("expected *BootstrapError, got %T", err)
	}
	if be.Exit != bootstrapNoExitCode {
		t.Errorf("Exit = %d, want bootstrapNoExitCode (%d) for ENOENT", be.Exit, bootstrapNoExitCode)
	}
	if !strings.Contains(be.Error(), "no exit code") {
		t.Errorf("Error() should label as 'no exit code', got: %s", be.Error())
	}
}

// Test 8d — runBootstrap tees output to the progress writer so a slow
// installer is visible in real time.
func TestRunBootstrap_TeesProgress(t *testing.T) {
	dir := t.TempDir()
	m := &manifest.Manifest{
		SchemaVersion: manifest.SchemaVersion2,
		Runtime:       manifest.Runtime{Bootstrap: []string{"sh", "-c", "echo PROGRESS_STDOUT; echo PROGRESS_STDERR >&2"}},
	}
	var progress bytes.Buffer
	if err := runBootstrap(context.Background(), dir, m, &progress); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	got := progress.String()
	if !strings.Contains(got, "PROGRESS_STDOUT") {
		t.Errorf("progress missing PROGRESS_STDOUT: %q", got)
	}
	if !strings.Contains(got, "PROGRESS_STDERR") {
		t.Errorf("progress missing PROGRESS_STDERR: %q", got)
	}
}

// Test 9 — state.json round-trips the per-extractor map.
func TestInitState_RoundTripExtractors(t *testing.T) {
	tsAt := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	original := InitState{
		AuditVersion: "test",
		AppliedAt:    "2026-06-01T00:00:00Z",
		Files:        map[string]InitStateFile{},
		Extractors: map[string]ExtractorState{
			"typescript": {BootstrapStatus: BootstrapOK, BootstrappedAt: &tsAt},
			"swift":      {BootstrapStatus: BootstrapFailed, LastError: "missing toolchain"},
		},
	}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	var got InitState
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Extractors["typescript"].BootstrapStatus != BootstrapOK {
		t.Errorf("typescript status lost: %+v", got.Extractors["typescript"])
	}
	if got.Extractors["swift"].LastError != "missing toolchain" {
		t.Errorf("swift LastError lost: %+v", got.Extractors["swift"])
	}
}

// Test 10 + 10a — state.json without the extractors field unmarshals with
// Extractors == nil; callers see effectively pending entries.
func TestInitState_LegacyJSONLoadsNilMap(t *testing.T) {
	// Simulates state.json from the binary immediately before the
	// per-extractor tracking change — keep the field set frozen for this test
	// even as InitState grows new fields.
	legacy := []byte(`{
		"audit_version": "0.0.0",
		"source_repo_root": "/tmp/old",
		"applied_at": "2026-01-01T00:00:00Z",
		"files": {
			"extractors/typescript/manifest.toml": {"sha256": "abc"}
		}
	}`)
	var s InitState
	if err := json.Unmarshal(legacy, &s); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if s.Extractors != nil {
		t.Errorf("Extractors should be nil for legacy state.json, got %v", s.Extractors)
	}
	zero := s.Extractors["typescript"] // nil-map read returns zero value
	if zero.BootstrapStatus != "" {
		t.Errorf("nil-map read should give zero ExtractorState, got %+v", zero)
	}
}

// Test 10b — Init re-run on the same dest with no source changes is
// idempotent: state.json's bootstrapped_at does not advance and runBootstrap
// is not invoked again (verified via a sentinel-file mtime). The fixture's
// manifest has no bootstrap declared, so we set one explicitly.
func TestInit_IdempotentNoFileChange(t *testing.T) {
	src := setupSource(t)
	sentinel := filepath.Join(t.TempDir(), "bootstrap-mtime")
	writeBootstrapManifest(t, src, []string{"sh", "-c", "touch " + sentinel})
	dest := filepath.Join(t.TempDir(), "audit-home")

	mustInit(t, src, dest)
	first, err := os.Stat(sentinel)
	if err != nil {
		t.Fatalf("bootstrap did not run on first init: %v", err)
	}
	firstState := readState(t, dest)
	firstAt := firstState.Extractors["typescript"].BootstrappedAt
	if firstState.Extractors["typescript"].BootstrapStatus != BootstrapOK {
		t.Fatalf("first init bootstrap not ok: %+v", firstState.Extractors["typescript"])
	}

	// Sleep enough that any mtime change would be visible.
	time.Sleep(10 * time.Millisecond)
	mustInit(t, src, dest)

	second, err := os.Stat(sentinel)
	if err != nil {
		t.Fatal(err)
	}
	if !second.ModTime().Equal(first.ModTime()) {
		t.Errorf("idempotent re-init re-ran bootstrap: first=%v second=%v",
			first.ModTime(), second.ModTime())
	}

	secondState := readState(t, dest)
	secondAt := secondState.Extractors["typescript"].BootstrappedAt
	if firstAt == nil || secondAt == nil || !secondAt.Equal(*firstAt) {
		t.Errorf("BootstrappedAt advanced on idempotent re-init: first=%v second=%v",
			firstAt, secondAt)
	}
}

// Test 10c — schema-2 manifest without bootstrap is recorded as n-a.
func TestInit_NoBootstrapRecordsNA(t *testing.T) {
	src := setupSource(t)
	body := `schema_version = 2
[extractor]
name = "typescript"
version = "0.0.1"
[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["node", "type-catalog.mjs", "--output", "{output}"]
`
	if err := os.WriteFile(filepath.Join(src, "extractors/typescript/manifest.toml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "audit-home")
	mustInit(t, src, dest)

	state := readState(t, dest)
	got := state.Extractors["typescript"]
	if got.BootstrapStatus != BootstrapNA {
		t.Errorf("status = %q, want %q (%+v)", got.BootstrapStatus, BootstrapNA, got)
	}
}

// Test 10d — calling EnsureExtractorsMap on a freshly unmarshaled state
// with nil Extractors lets the caller write without panic.
func TestInitState_EnsureExtractorsMapNilSafe(t *testing.T) {
	var s InitState
	// Sanity: nil before EnsureExtractorsMap.
	if s.Extractors != nil {
		t.Fatalf("expected nil Extractors, got %v", s.Extractors)
	}

	// Direct assignment to a nil map would panic; via the helper it does not.
	m := s.EnsureExtractorsMap()
	m["foo"] = ExtractorState{BootstrapStatus: BootstrapOK}

	if s.Extractors["foo"].BootstrapStatus != BootstrapOK {
		t.Errorf("write via EnsureExtractorsMap not visible on InitState: %+v", s.Extractors)
	}
}

// embeddedFixture returns a pair of fstest.MapFS instances simulating the
// brew embedded source: one extractors subtree, one queries subtree.
func embeddedFixture(t *testing.T) []SubtreeSrc {
	t.Helper()
	extractorsFS := fstest.MapFS{
		"typescript/manifest.toml": &fstest.MapFile{
			Data: []byte(`schema_version = 2
[extractor]
name = "typescript"
version = "0.0.1"
[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["node", "type-catalog.mjs", "--output", "{output}"]
[runtime]
requires = ["node >= 18"]
`),
			Mode: 0o444,
		},
		"typescript/type-catalog.mjs": &fstest.MapFile{
			Data: []byte("// extractor\n"),
			Mode: 0o444,
		},
	}
	queriesFS := fstest.MapFS{
		"_canonical.jq":        &fstest.MapFile{Data: []byte("# helper\n"), Mode: 0o444},
		"exact-duplicates.jq":  &fstest.MapFile{Data: []byte("#! query: exact-duplicates\n"), Mode: 0o444},
	}
	return []SubtreeSrc{
		{RelPath: "extractors", FS: extractorsFS, Embedded: true},
		{RelPath: "pipeline/queries", FS: queriesFS, Embedded: true},
	}
}

// Test 11 — `code-audit init` (no args) succeeds with embedded source;
// state.json records source_repo_root: "<embedded>".
func TestInit_NoFromUsesEmbedded(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--dest", dest}, &out, embeddedFixture(t))
	if exit != 0 {
		t.Fatalf("Init exit=%d, out=%s", exit, out.String())
	}
	state := readState(t, dest)
	if state.SourceRepoRoot != "<embedded>" {
		t.Errorf("SourceRepoRoot = %q, want <embedded>", state.SourceRepoRoot)
	}
	if state.SourceCommitSHA != "" {
		t.Errorf("SourceCommitSHA = %q, want empty for embedded", state.SourceCommitSHA)
	}
	for _, rel := range []string{
		"extractors/typescript/manifest.toml",
		"extractors/typescript/type-catalog.mjs",
		"pipeline/queries/_canonical.jq",
		"pipeline/queries/exact-duplicates.jq",
	} {
		if _, err := os.Stat(filepath.Join(dest, rel)); err != nil {
			t.Errorf("missing copied file %s: %v", rel, err)
		}
	}
}

// Test 11a — embedded-source init runs bootstrap once; state.json records
// status n-a since the fixture's manifest declares no [runtime].bootstrap.
func TestInit_NoFromRecordsBootstrapNA(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--dest", dest}, &out, embeddedFixture(t))
	if exit != 0 {
		t.Fatalf("Init exit=%d, out=%s", exit, out.String())
	}
	state := readState(t, dest)
	got := state.Extractors["typescript"]
	if got.BootstrapStatus != BootstrapNA {
		t.Errorf("status = %q, want %q (%+v)", got.BootstrapStatus, BootstrapNA, got)
	}
}

// Test 11b — embedded-source init re-run with no source changes is
// idempotent: no second bootstrap, no file writes, exit 0.
func TestInit_NoFromIdempotent(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "audit-home")
	emb := embeddedFixture(t)

	var first bytes.Buffer
	if exit := Init(context.Background(), []string{"--dest", dest}, &first, emb); exit != 0 {
		t.Fatalf("first Init exit=%d, out=%s", exit, first.String())
	}
	stateBefore := readState(t, dest)

	var second bytes.Buffer
	if exit := Init(context.Background(), []string{"--dest", dest}, &second, emb); exit != 0 {
		t.Fatalf("second Init exit=%d, out=%s", exit, second.String())
	}
	if !strings.Contains(second.String(), "0 new, 0 upgraded") {
		t.Errorf("expected idempotent summary, got: %s", second.String())
	}
	stateAfter := readState(t, dest)
	beforeAt := stateBefore.Extractors["typescript"].BootstrappedAt
	afterAt := stateAfter.Extractors["typescript"].BootstrappedAt
	if beforeAt == nil || afterAt == nil || !afterAt.Equal(*beforeAt) {
		t.Errorf("BootstrappedAt advanced on idempotent re-init: before=%v after=%v", beforeAt, afterAt)
	}
}

// Test 12 — `code-audit init --from <checkout>` still works.
func TestInit_FromCheckoutStillWorks(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit != 0 {
		t.Fatalf("Init exit=%d, out=%s", exit, out.String())
	}
	state := readState(t, dest)
	if state.SourceRepoRoot != src {
		t.Errorf("SourceRepoRoot = %q, want %q", state.SourceRepoRoot, src)
	}
}

// Test 12a — os.DirFS(src) and embedded subtrees produce structurally
// equivalent plans: same relDest set, same SHAs.
func TestInit_FilesystemAndEmbeddedPlansEquivalent(t *testing.T) {
	// Build a synthetic source tree on the filesystem mirroring the
	// embedded fixture exactly.
	src := t.TempDir()
	emb := embeddedFixture(t)
	for _, st := range emb {
		mfs := st.FS.(fstest.MapFS)
		for path, file := range mfs {
			full := filepath.Join(src, filepath.FromSlash(st.RelPath), filepath.FromSlash(path))
			if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(full, file.Data, 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}

	dstFS := t.TempDir()
	fsSubtrees := []SubtreeSrc{
		{RelPath: "extractors", FS: os.DirFS(filepath.Join(src, "extractors"))},
		{RelPath: "pipeline/queries", FS: os.DirFS(filepath.Join(src, "pipeline/queries"))},
	}
	planFS, err := buildCopyPlan(context.Background(), fsSubtrees, dstFS)
	if err != nil {
		t.Fatal(err)
	}
	dstEmb := t.TempDir()
	planEmb, err := buildCopyPlan(context.Background(), emb, dstEmb)
	if err != nil {
		t.Fatal(err)
	}

	// Compare on (relDest, content SHA) tuples — srcFS pointers differ by
	// construction, and dstAbs differs by tempdir.
	tuple := func(plan []fileClassification, root string) map[string]string {
		t.Helper()
		got := map[string]string{}
		for _, c := range plan {
			sha, err := sha256FS(c.srcFS, c.srcRel)
			if err != nil {
				t.Fatalf("sha %s: %v", c.relDest, err)
			}
			got[c.relDest] = sha
		}
		return got
	}
	gotFS := tuple(planFS, dstFS)
	gotEmb := tuple(planEmb, dstEmb)
	if len(gotFS) == 0 {
		t.Fatal("filesystem plan is empty")
	}
	if len(gotFS) != len(gotEmb) {
		t.Fatalf("plan size differs: fs=%d emb=%d", len(gotFS), len(gotEmb))
	}
	for k, fsSHA := range gotFS {
		if embSHA, ok := gotEmb[k]; !ok {
			t.Errorf("embedded plan missing %q", k)
		} else if fsSHA != embSHA {
			t.Errorf("%q sha differs: fs=%s emb=%s", k, fsSHA, embSHA)
		}
	}
}

// Test 12b — --from with a dir containing a symlink loop does not recurse
// into the symlink (behaviour change from filepath.WalkDir).
func TestInit_FromDirSymlinkNotRecursed(t *testing.T) {
	src := setupSource(t)
	// Plant a symlink inside extractors/typescript that points back at the
	// source root. With the old filepath.WalkDir code this looped; the new
	// fs.WalkDir-based code visits the symlink as an entry but doesn't
	// recurse into it.
	loopDir := filepath.Join(src, "extractors", "typescript", "loop")
	if err := os.Symlink(src, loopDir); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit != 0 {
		t.Fatalf("Init exit=%d (expected no-recurse to succeed), out=%s", exit, out.String())
	}
	// Confirm the loop wasn't traversed — there should be no
	// extractors/typescript/loop/extractors/... explosion under dest.
	if _, err := os.Stat(filepath.Join(dest, "extractors", "typescript", "loop", "extractors")); err == nil {
		t.Errorf("symlink was traversed; expected fs.WalkDir to skip it")
	}
}

// Test 12c — embedded files starting with `#!` get 0o755; non-shebang
// files get 0o644. Covers the shebang heuristic's edge cases.
func TestInit_EmbeddedShebangSetsExecBit(t *testing.T) {
	emb := []SubtreeSrc{
		{RelPath: "extractors", FS: fstest.MapFS{
			"x/manifest.toml": &fstest.MapFile{Data: []byte(`schema_version = 1
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]
`), Mode: 0o444},
			"x/script.sh":   &fstest.MapFile{Data: []byte("#!/bin/sh\nexit 0\n"), Mode: 0o444},
			"x/plain.txt":   &fstest.MapFile{Data: []byte("hello\n"), Mode: 0o444},
			"x/empty.txt":   &fstest.MapFile{Data: []byte{}, Mode: 0o444},
			"x/onebyte.txt": &fstest.MapFile{Data: []byte("#"), Mode: 0o444},
			"x/comment.txt": &fstest.MapFile{Data: []byte("# leading hash, no bang\n"), Mode: 0o444},
		}, Embedded: true},
		{RelPath: "pipeline/queries", FS: fstest.MapFS{
			"_canonical.jq": &fstest.MapFile{Data: []byte("# helper\n"), Mode: 0o444},
		}, Embedded: true},
	}
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--dest", dest}, &out, emb)
	if exit != 0 {
		t.Fatalf("Init exit=%d, out=%s", exit, out.String())
	}

	cases := []struct {
		path string
		exec bool
	}{
		{"extractors/x/script.sh", true},
		{"extractors/x/plain.txt", false},
		{"extractors/x/empty.txt", false},
		{"extractors/x/onebyte.txt", false},
		{"extractors/x/comment.txt", false},
	}
	for _, tc := range cases {
		info, err := os.Stat(filepath.Join(dest, filepath.FromSlash(tc.path)))
		if err != nil {
			t.Errorf("stat %s: %v", tc.path, err)
			continue
		}
		isExec := info.Mode().Perm()&0o111 != 0
		if isExec != tc.exec {
			t.Errorf("%s exec=%v, want %v (mode=%v)", tc.path, isExec, tc.exec, info.Mode().Perm())
		}
	}
}

// Test 12d — Init with --from <dir> that's missing an extractor subdir
// fails validateSource (the existing safety net) before any plan walk.
// Pairs with the discovery-time analogue in Phase 5's test 19b.
func TestInit_FromMissingSubdirFailsValidateSource(t *testing.T) {
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "extractors"), 0o755); err != nil {
		t.Fatal(err)
	}
	// pipeline/queries deliberately missing.
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit == 0 {
		t.Fatalf("expected non-zero exit for missing subdir, out=%s", out.String())
	}
	if !strings.Contains(out.String(), "pipeline/queries") {
		t.Errorf("error should mention pipeline/queries: %s", out.String())
	}
}

// Test 12e — Init --from <non-git-dir> succeeds; state.SourceCommitSHA == "".
func TestInit_FromNonGitDirGraceful(t *testing.T) {
	src := setupSource(t)
	// Remove .git to simulate a non-checkout source tree.
	if err := os.RemoveAll(filepath.Join(src, ".git")); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "audit-home")
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit != 0 {
		t.Fatalf("Init exit=%d, out=%s", exit, out.String())
	}
	state := readState(t, dest)
	if state.SourceCommitSHA != "" {
		t.Errorf("SourceCommitSHA = %q, want empty", state.SourceCommitSHA)
	}
}

// Test 10g — prior BootstrapFailed status triggers a retry on next init
// even when no source files changed (covers transient-failure recovery
// without requiring the user to know about --upgrade).
func TestInit_RetriesPriorFailure(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")

	// Seed state.json with a prior failure for typescript.
	mustInit(t, src, dest)
	state := readState(t, dest)
	prior, ok := state.Extractors["typescript"]
	if !ok {
		t.Fatalf("expected typescript entry, got %+v", state.Extractors)
	}
	prior.BootstrapStatus = BootstrapFailed
	prior.LastError = "transient: ECONNRESET"
	state.Extractors["typescript"] = prior
	if err := saveState(dest, &state); err != nil {
		t.Fatal(err)
	}

	// Re-init with no source changes — should retry typescript (failed
	// prior) even though nothing was copied/upgraded.
	sentinel := filepath.Join(t.TempDir(), "retry-witness")
	writeBootstrapManifest(t, src, []string{"sh", "-c", "touch " + sentinel})
	// Re-init: the manifest file is now DIFFERENT from prior pristine
	// (we just wrote a new bootstrap manifest), so it lands as DIRTY
	// against the prior pristine record. Use --force to overwrite and
	// upgrade. The retry path is then exercised by the touched + failed
	// union.
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--force"}, &out, nil)
	if exit != 0 {
		t.Fatalf("retry Init exit=%d, out=%s", exit, out.String())
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Errorf("bootstrap did not retry: %v", err)
	}
	after := readState(t, dest)
	if after.Extractors["typescript"].BootstrapStatus != BootstrapOK {
		t.Errorf("retried bootstrap status = %q, want %q", after.Extractors["typescript"].BootstrapStatus, BootstrapOK)
	}
	if after.Extractors["typescript"].LastError != "" {
		t.Errorf("LastError should clear on success, got %q", after.Extractors["typescript"].LastError)
	}
}

// Test 10h — extractor entries for sources no longer present are pruned
// from state.Extractors on the next init (otherwise BootstrapOK lingers
// for an extractor whose source directory was deleted).
func TestInit_PrunesRemovedExtractors(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")

	// Plant a second 'phantom' extractor in state.Extractors that has
	// no source files in the current src tree.
	mustInit(t, src, dest)
	state := readState(t, dest)
	now := time.Now().UTC()
	state.Extractors["phantom"] = ExtractorState{
		BootstrapStatus: BootstrapOK,
		BootstrappedAt:  &now,
	}
	if err := saveState(dest, &state); err != nil {
		t.Fatal(err)
	}

	// Re-init — should prune phantom (no source files for it).
	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out, nil)
	if exit != 0 {
		t.Fatalf("Init exit=%d, out=%s", exit, out.String())
	}
	after := readState(t, dest)
	if _, ok := after.Extractors["phantom"]; ok {
		t.Errorf("phantom extractor entry should be pruned, still present: %+v", after.Extractors["phantom"])
	}
	if _, ok := after.Extractors["typescript"]; !ok {
		t.Errorf("typescript entry should be preserved, got %+v", after.Extractors)
	}
}

// Test 10i — when manifest.toml is DIRTY-skipped, bootstrap MUST NOT run
// for that extractor (would honor user-edited argv). State.json keeps
// the prior status; user is told to --force if they really want it.
func TestInit_SkipsBootstrapWhenManifestDirty(t *testing.T) {
	src := setupSource(t)
	dest := filepath.Join(t.TempDir(), "audit-home")
	sentinel := filepath.Join(t.TempDir(), "should-not-run")
	writeBootstrapManifest(t, src, []string{"sh", "-c", "touch " + sentinel})
	mustInit(t, src, dest)
	priorState := readState(t, dest)
	priorAt := priorState.Extractors["typescript"].BootstrappedAt

	// Locally edit dest manifest.toml (DIRTY) and update source so other
	// files are upgraded — extractor is touched but manifest is skipped.
	destManifest := filepath.Join(dest, "extractors/typescript/manifest.toml")
	if err := os.WriteFile(destManifest, []byte("schema_version = 99\n# locally edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	srcExtractor := filepath.Join(src, "extractors/typescript/type-catalog.mjs")
	if err := os.WriteFile(srcExtractor, []byte("// extractor v2\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Clear the first-init sentinel so we can detect a (forbidden) retry.
	os.Remove(sentinel)

	var out bytes.Buffer
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--upgrade"}, &out, nil)
	// dirty manifest → exit=1 (existing skip-dirty contract).
	if exit != 1 {
		t.Fatalf("Init exit=%d (want 1 for dirty), out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "SKIPPED") || !strings.Contains(out.String(), "manifest.toml is locally modified") {
		t.Errorf("expected SKIPPED bootstrap warning, got: %s", out.String())
	}
	if _, err := os.Stat(sentinel); err == nil {
		t.Errorf("bootstrap should NOT have run while manifest is DIRTY")
	}
	after := readState(t, dest)
	if after.Extractors["typescript"].BootstrappedAt == nil ||
		priorAt == nil ||
		!after.Extractors["typescript"].BootstrappedAt.Equal(*priorAt) {
		t.Errorf("BootstrappedAt advanced despite skipped bootstrap: prior=%v after=%v",
			priorAt, after.Extractors["typescript"].BootstrappedAt)
	}
}

// Test 10e — downgrade simulation: an old binary (whose InitState has no
// Extractors field) reads then writes state.json, dropping the extractors
// block. Next new-binary read sees Extractors == nil, ready to be re-
// populated on next bootstrap pass.
func TestInitState_DowngradeSimulation(t *testing.T) {
	// (1) JSON with extractors populated.
	newFormat, err := json.Marshal(InitState{
		AuditVersion: "new",
		AppliedAt:    "2026-06-01T00:00:00Z",
		Files:        map[string]InitStateFile{},
		Extractors: map[string]ExtractorState{
			"typescript": {BootstrapStatus: BootstrapOK},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(newFormat), "extractors") {
		t.Fatalf("precondition: new-format JSON must contain extractors, got %s", string(newFormat))
	}

	// (2) Old InitState shape — no Extractors field.
	type oldInitState struct {
		AuditVersion    string                   `json:"audit_version"`
		SourceRepoRoot  string                   `json:"source_repo_root"`
		SourceCommitSHA string                   `json:"source_commit_sha,omitempty"`
		AppliedAt       string                   `json:"applied_at"`
		Files           map[string]InitStateFile `json:"files"`
	}
	var old oldInitState
	if err := json.Unmarshal(newFormat, &old); err != nil {
		t.Fatalf("old binary failed to unmarshal new JSON: %v", err)
	}

	// (3) Old binary re-marshals — extractors drops out.
	roundTripped, err := json.Marshal(old)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(roundTripped), "extractors") {
		t.Errorf("old-binary round-trip should drop extractors: %s", string(roundTripped))
	}

	// (4) New binary reads downgrade-roundtripped JSON: Extractors is nil,
	// callers see pending — auto-recovery on next bootstrap pass.
	var recovered InitState
	if err := json.Unmarshal(roundTripped, &recovered); err != nil {
		t.Fatal(err)
	}
	if recovered.Extractors != nil {
		t.Errorf("post-downgrade Extractors should be nil, got %v", recovered.Extractors)
	}
}
