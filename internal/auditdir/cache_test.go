package auditdir

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOpenFreshAndSave(t *testing.T) {
	root := t.TempDir()
	c, err := Open(root, "0.1.0")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if c.meta.Root != root {
		t.Errorf("Root = %q, want %q", c.meta.Root, root)
	}
	if err := c.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(root, ".audit", "meta.json"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	var m Meta
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if m.AuditVersion != "0.1.0" {
		t.Errorf("AuditVersion = %q", m.AuditVersion)
	}
	if _, err := time.Parse(time.RFC3339, m.LastTouchedAt); err != nil {
		t.Errorf("LastTouchedAt %q: %v", m.LastTouchedAt, err)
	}
}

func TestOpenAddsGitignore(t *testing.T) {
	root := t.TempDir()
	if _, err := Open(root, "0.1.0"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, ".gitignore"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if !strings.Contains(string(data), ".audit/") {
		t.Errorf(".gitignore missing .audit/: %q", string(data))
	}
	// Re-open: still one occurrence.
	if _, err := Open(root, "0.1.0"); err != nil {
		t.Fatal(err)
	}
	data2, _ := os.ReadFile(filepath.Join(root, ".gitignore"))
	if strings.Count(string(data2), ".audit/") != 1 {
		t.Errorf("idempotency broken; .gitignore: %q", string(data2))
	}
}

func TestPutCatalogAndPath(t *testing.T) {
	root := t.TempDir()
	c, _ := Open(root, "0.1.0")
	// Write a fake catalog.
	catPath := filepath.Join(c.Dir, "catalogs", "type-catalog.json")
	body := `{"schema_version":"1.1","extractor":{"name":"type-catalog"},"entries":[]}`
	if err := os.WriteFile(catPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := c.PutCatalog("type-catalog", "type-catalog.json", map[string]any{"root": "/tmp"}); err != nil {
		t.Fatalf("PutCatalog: %v", err)
	}
	p, ok := c.CatalogPath("type-catalog")
	if !ok || p != catPath {
		t.Errorf("CatalogPath = %q, %v", p, ok)
	}
	e := c.meta.Catalogs["type-catalog"]
	if e.SourceSHA == "" {
		t.Error("SourceSHA empty")
	}
	if e.EnvelopeSummary == nil || e.EnvelopeSummary.SchemaVersion != "1.1" {
		t.Errorf("EnvelopeSummary missing schema_version: %+v", e.EnvelopeSummary)
	}
}

func TestStatusStaleness(t *testing.T) {
	root := t.TempDir()
	c, _ := Open(root, "0.1.0")
	catPath := filepath.Join(c.Dir, "catalogs", "type-catalog.json")
	if err := os.WriteFile(catPath, []byte(`{"schema_version":"1.1","entries":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := c.PutCatalog("type-catalog", "type-catalog.json", nil); err != nil {
		t.Fatal(err)
	}
	// Source file newer than catalog mtime.
	src := filepath.Join(root, "src", "x.ts")
	if err := os.MkdirAll(filepath.Dir(src), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, []byte("export const x = 1;"), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(src, future, future); err != nil {
		t.Fatal(err)
	}
	rows, err := c.Status()
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %d", len(rows))
	}
	if rows[0].StaleSourceCount < 1 {
		t.Errorf("StaleSourceCount = %d, want >=1", rows[0].StaleSourceCount)
	}
}

func TestStatusSkipsDotdirs(t *testing.T) {
	root := t.TempDir()
	c, _ := Open(root, "0.1.0")
	if err := os.WriteFile(filepath.Join(c.Dir, "catalogs", "type-catalog.json"),
		[]byte(`{"schema_version":"1.1","entries":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := c.PutCatalog("type-catalog", "type-catalog.json", nil); err != nil {
		t.Fatal(err)
	}
	// Create a newer file under a dotdir — should be skipped.
	dot := filepath.Join(root, ".git", "objects")
	if err := os.MkdirAll(dot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dot, "blob"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(2 * time.Second)
	_ = os.Chtimes(filepath.Join(dot, "blob"), future, future)
	rows, _ := c.Status()
	if rows[0].StaleSourceCount != 0 {
		t.Errorf("StaleSourceCount = %d, want 0 (dotdir should be skipped)", rows[0].StaleSourceCount)
	}
}
