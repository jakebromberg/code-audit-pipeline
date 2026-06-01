package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--upgrade"}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--force"}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--upgrade"}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--upgrade"}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest, "--dry-run"}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out)
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
	exit := Init(context.Background(), []string{"--dest", dest}, &out)
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
	exit := Init(context.Background(), []string{"--from", src, "--dest", dest}, &out)
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
	err := runBootstrap(context.Background(), dir, m)
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
	err := runBootstrap(context.Background(), dir, m)
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

// Test 8b — runBootstrap respects context cancellation.
func TestRunBootstrap_ContextCancellation(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()
	m := &manifest.Manifest{
		SchemaVersion: manifest.SchemaVersion2,
		Runtime:       manifest.Runtime{Bootstrap: []string{"sh", "-c", "sleep 30"}},
	}
	start := time.Now()
	err := runBootstrap(ctx, dir, m)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("expected cancellation error, got nil")
	}
	if elapsed > 5*time.Second {
		t.Errorf("runBootstrap did not return promptly under ctx cancel: %v", elapsed)
	}
}

// Test 9 — state.json round-trips the per-extractor map.
func TestInitState_RoundTripExtractors(t *testing.T) {
	original := InitState{
		AuditVersion: "test",
		AppliedAt:    "2026-06-01T00:00:00Z",
		Files:        map[string]InitStateFile{},
		Extractors: map[string]ExtractorState{
			"typescript": {BootstrapStatus: BootstrapOK, BootstrappedAt: time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)},
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
	if !secondState.Extractors["typescript"].BootstrappedAt.Equal(firstAt) {
		t.Errorf("BootstrappedAt advanced on idempotent re-init: first=%v second=%v",
			firstAt, secondState.Extractors["typescript"].BootstrappedAt)
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
