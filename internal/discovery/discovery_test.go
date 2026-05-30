package discovery

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func newQueriesDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	if err := os.MkdirAll(filepath.Join(d, "pipeline", "queries"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "pipeline", "queries", "_canonical.jq"), []byte("# canon"), 0o644); err != nil {
		t.Fatal(err)
	}
	return d
}

func TestQueriesFlagWins(t *testing.T) {
	flagDir := newQueriesDir(t)
	cwd := newQueriesDir(t)
	embedded := fstest.MapFS{"_canonical.jq": &fstest.MapFile{Data: []byte("# emb")}}
	src, err := ResolveQueriesDir(QueryOpts{
		Flag: filepath.Join(flagDir, "pipeline", "queries"),
		CWD:  cwd,
	}, embedded)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !strings.Contains(src.Label, "--queries-dir") {
		t.Errorf("Label = %q, want --queries-dir hit", src.Label)
	}
	if src.FS != nil {
		t.Error("FS should be nil when filesystem source wins")
	}
}

func TestQueriesEmbeddedFallback(t *testing.T) {
	// Empty cwd (no pipeline/queries) and no flag — embedded wins.
	tmp := t.TempDir()
	embedded := fstest.MapFS{"_canonical.jq": &fstest.MapFile{Data: []byte("# emb")}}
	src, err := ResolveQueriesDir(QueryOpts{CWD: tmp}, embedded)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if src.FS == nil {
		t.Error("FS should be populated for embedded fallback")
	}
	if src.Label != "embedded" {
		t.Errorf("Label = %q", src.Label)
	}
}

func TestExtractorsCwdWins(t *testing.T) {
	cwd := t.TempDir()
	if err := os.MkdirAll(filepath.Join(cwd, "extractors", "typescript"), 0o755); err != nil {
		t.Fatal(err)
	}
	path, label, err := ResolveExtractorsDir(ExtractorOpts{CWD: cwd})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !strings.Contains(path, "extractors") {
		t.Errorf("path = %q", path)
	}
	if !strings.Contains(label, "cwd-relative") {
		t.Errorf("label = %q", label)
	}
}

func TestExtractorsNoSource(t *testing.T) {
	tmp := t.TempDir()
	_, _, err := ResolveExtractorsDir(ExtractorOpts{CWD: tmp})
	if err == nil {
		t.Error("expected error when no extractors directory found")
	}
}

func TestExtractorsHomeFallback(t *testing.T) {
	tmp := t.TempDir()
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".config", "audit", "extractors", "typescript"), 0o755); err != nil {
		t.Fatal(err)
	}
	path, label, err := ResolveExtractorsDir(ExtractorOpts{CWD: tmp, HomeDir: home})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if !strings.Contains(path, ".config/audit/extractors") {
		t.Errorf("path = %q", path)
	}
	if !strings.Contains(label, "~/.config") {
		t.Errorf("label = %q", label)
	}
}
