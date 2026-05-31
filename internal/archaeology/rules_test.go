package archaeology

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadRuleTextRootOnly(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "CLAUDE.md"), "# Repo rules\n")

	got, err := ReadRuleText(root)
	if err != nil {
		t.Fatalf("ReadRuleText: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row, got %d: %+v", len(got), got)
	}
	if got[0].File != "CLAUDE.md" {
		t.Errorf("file=%q want CLAUDE.md", got[0].File)
	}
	if got[0].Scope != "repo" {
		t.Errorf("scope=%q want repo", got[0].Scope)
	}
	if got[0].Body != "# Repo rules\n" {
		t.Errorf("body mismatch: %q", got[0].Body)
	}
}

func TestReadRuleTextNestedPackageScope(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "CLAUDE.md"), "repo rules")
	writeFile(t, filepath.Join(root, "Shared", "Core", "CLAUDE.md"), "core package rules")
	writeFile(t, filepath.Join(root, "Shared", "Networking", "CLAUDE.md"), "net rules")

	got, err := ReadRuleText(root)
	if err != nil {
		t.Fatalf("ReadRuleText: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 rows, got %d", len(got))
	}
	// Sorted ascending by file path: top-level CLAUDE.md sorts before nested.
	wantOrder := []struct{ file, scope string }{
		{"CLAUDE.md", "repo"},
		{"Shared/Core/CLAUDE.md", "package:Core"},
		{"Shared/Networking/CLAUDE.md", "package:Networking"},
	}
	for i, w := range wantOrder {
		if got[i].File != w.file {
			t.Errorf("row %d file=%q want %q", i, got[i].File, w.file)
		}
		if got[i].Scope != w.scope {
			t.Errorf("row %d scope=%q want %q", i, got[i].Scope, w.scope)
		}
	}
}

func TestReadRuleTextSkipsDotdirsAndVendor(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "CLAUDE.md"), "real")
	writeFile(t, filepath.Join(root, ".claude", "CLAUDE.md"), "should not appear")
	writeFile(t, filepath.Join(root, "node_modules", "lib", "CLAUDE.md"), "vendor")
	writeFile(t, filepath.Join(root, ".git", "CLAUDE.md"), "git internal")

	got, err := ReadRuleText(root)
	if err != nil {
		t.Fatalf("ReadRuleText: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row, got %d: %+v", len(got), got)
	}
	if got[0].File != "CLAUDE.md" {
		t.Errorf("file=%q want top-level CLAUDE.md", got[0].File)
	}
}

func TestReadRuleTextNoFilesIsEmpty(t *testing.T) {
	root := t.TempDir()
	got, err := ReadRuleText(root)
	if err != nil {
		t.Fatalf("ReadRuleText: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("want empty, got %d rows", len(got))
	}
}

// writeFile creates `path` (including parent dirs) with the given content.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
