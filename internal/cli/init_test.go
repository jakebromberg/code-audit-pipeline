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
