package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	mkfile("extractors/typescript/manifest.toml", "schema_version = 1\n")
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
// `audit init --upgrade` happy path was only exercised indirectly via the
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
