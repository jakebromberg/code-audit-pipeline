package extractor

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
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
