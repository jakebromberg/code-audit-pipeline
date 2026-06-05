package extractor

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

func TestSubstitutePlaceholders(t *testing.T) {
	repl := map[string]string{
		"{root}":   "/tmp/repo",
		"{output}": "/tmp/.audit/catalogs/x.json",
	}
	got := substitute("--root={root}", repl)
	if got != "--root=/tmp/repo" {
		t.Errorf("got %q", got)
	}
	got = substitute("{output}", repl)
	if got != "/tmp/.audit/catalogs/x.json" {
		t.Errorf("got %q", got)
	}
}

func TestWhenSatisfied(t *testing.T) {
	cases := []struct {
		when string
		args Args
		want bool
	}{
		{"shared_set", Args{Shared: "/x"}, true},
		{"shared_set", Args{}, false},
		{"include_tests_set", Args{IncludeTests: true}, true},
		{"min_body_lines_set", Args{MinBodyLines: 5}, true},
		{"min_body_lines_set", Args{}, false},
		{"scan_header_set", Args{ScanHeader: true}, true},
		{"scan_header_set", Args{}, false},
		{"scan_marks_set", Args{ScanMarks: true}, true},
		{"scan_marks_set", Args{}, false},
	}
	for _, c := range cases {
		if got := whenSatisfied(c.when, c.args); got != c.want {
			t.Errorf("whenSatisfied(%q) = %v, want %v", c.when, got, c.want)
		}
	}
}

func TestCheckUnresolved(t *testing.T) {
	if err := checkUnresolved([]string{"node", "x.mjs", "--root", "/repo"}); err != nil {
		t.Errorf("clean argv: %v", err)
	}
	if err := checkUnresolved([]string{"node", "x.mjs", "--shared", "{shared}"}); err == nil {
		t.Error("unresolved {shared} not flagged")
	}
}

// TestWithHint verifies that withHint appends the manifest's setup_hint
// when one is declared, and is a no-op when the hint is empty. Errors must
// still unwrap to the original cause (errors.Is must hold) so callers can
// inspect them.
func TestWithHint(t *testing.T) {
	base := errors.New("boom")

	if got := withHint(base, ""); got != base {
		t.Errorf("withHint with empty hint should be a no-op; got %v", got)
	}

	wrapped := withHint(base, "Run npm install foo")
	if !strings.Contains(wrapped.Error(), "Run npm install foo") {
		t.Errorf("withHint did not include hint; got %q", wrapped.Error())
	}
	if !strings.Contains(wrapped.Error(), "hint:") {
		t.Errorf("withHint did not include 'hint:' prefix; got %q", wrapped.Error())
	}
	if !errors.Is(wrapped, base) {
		t.Errorf("withHint broke errors.Is unwrap chain")
	}
}

// TestRunSurfacesSetupHintOnSubprocessFailure builds a fake manifest whose
// only [[command]] invokes a script that exits 1, then asserts Run returns
// an error containing the manifest's [runtime].setup_hint. This locks the
// fix for issue #215.
func TestRunSurfacesSetupHintOnSubprocessFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture is POSIX-only")
	}
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh not on PATH")
	}

	tmp := t.TempDir()
	scriptDir := filepath.Join(tmp, "extractor")
	if err := os.MkdirAll(scriptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// A script that always exits 1 — stand-in for "node_modules missing".
	script := filepath.Join(scriptDir, "fail.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	cmd := manifest.Command{
		Catalog:    "type-catalog",
		OutputFile: "type-catalog.json",
		Invocation: []string{"sh", script, "--output", "{output}"},
	}
	args := Args{
		Root:      tmp,
		SetupHint: "Run npm install foo",
	}
	catalogs := filepath.Join(tmp, ".audit", "catalogs")

	_, err := Run(context.Background(), scriptDir, cmd, args, catalogs)
	if err == nil {
		t.Fatal("expected Run to fail when subprocess exits 1; got nil")
	}
	if !strings.Contains(err.Error(), "Run npm install foo") {
		t.Errorf("error did not surface setup_hint; got %q", err.Error())
	}
	if !strings.Contains(err.Error(), "hint:") {
		t.Errorf("error did not include 'hint:' prefix; got %q", err.Error())
	}
}

// TestRunOmitsHintWhenEmpty confirms that a failing subprocess without a
// SetupHint produces only the bare subprocess error — no trailing "hint:"
// line — so manifests that don't declare a hint are unaffected.
func TestRunOmitsHintWhenEmpty(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture is POSIX-only")
	}
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh not on PATH")
	}

	tmp := t.TempDir()
	scriptDir := filepath.Join(tmp, "extractor")
	if err := os.MkdirAll(scriptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(scriptDir, "fail.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	cmd := manifest.Command{
		Catalog:    "type-catalog",
		OutputFile: "type-catalog.json",
		Invocation: []string{"sh", script, "--output", "{output}"},
	}
	args := Args{Root: tmp} // no SetupHint
	catalogs := filepath.Join(tmp, ".audit", "catalogs")

	_, err := Run(context.Background(), scriptDir, cmd, args, catalogs)
	if err == nil {
		t.Fatal("expected Run to fail when subprocess exits 1; got nil")
	}
	if strings.Contains(err.Error(), "hint:") {
		t.Errorf("error should not include 'hint:' when SetupHint empty; got %q", err.Error())
	}
}

// TestRunRealExtractor runs the file-hashes extractor against this very
// project to confirm end-to-end wiring (manifest parse → placeholder
// substitution → subprocess → output file).
func TestRunRealExtractor(t *testing.T) {
	if _, err := os.Stat("../../extractors/file-hashes/manifest.toml"); err != nil {
		t.Skip("file-hashes manifest not present; running outside repo")
	}
	if _, err := os.Stat("../../extractors/file-hashes/file-hashes.mjs"); err != nil {
		t.Skip("file-hashes extractor script not present")
	}
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node not on PATH")
	}
	m, err := manifest.Parse("../../extractors/file-hashes/manifest.toml")
	if err != nil {
		t.Fatalf("manifest.Parse: %v", err)
	}
	tmp := t.TempDir()
	// Set up a tiny fake repo with one .ts file.
	repo := filepath.Join(tmp, "repo")
	if err := os.MkdirAll(filepath.Join(repo, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "src", "x.ts"), []byte("export const x = 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	abs, err := filepath.Abs("../../extractors/file-hashes")
	if err != nil {
		t.Fatal(err)
	}
	catalogs := filepath.Join(tmp, ".audit", "catalogs")
	res, err := Run(context.Background(), abs, m.Commands[0], Args{Root: repo}, catalogs)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(res) != 1 || res[0].Catalog != "file-hashes" {
		t.Fatalf("results = %+v", res)
	}
	if _, err := os.Stat(res[0].OutputPath); err != nil {
		t.Errorf("output missing: %v", err)
	}
}
