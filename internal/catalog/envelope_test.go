package catalog

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadEnvelopeWrapped(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "type-catalog.json")
	content := `{
  "schema_version": "1.1",
  "extractor": { "name": "type-catalog", "language": "typescript", "version": "0.5.0" },
  "entries": [ {"name": "A", "kind": "interface"} ]
}
`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	es, sum, err := ReadEnvelope(p)
	if err != nil {
		t.Fatalf("ReadEnvelope: %v", err)
	}
	if es.SchemaVersion != "1.1" {
		t.Errorf("schema_version = %q", es.SchemaVersion)
	}
	if len(es.Extractor) == 0 {
		t.Error("extractor empty")
	}
	if len(sum) != 64 {
		t.Errorf("sum len = %d, want 64", len(sum))
	}
}

func TestReadEnvelopeBareArray(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "v1.0.json")
	if err := os.WriteFile(p, []byte(`[{"name": "A"}]`), 0o644); err != nil {
		t.Fatal(err)
	}
	es, _, err := ReadEnvelope(p)
	if err != nil {
		t.Fatalf("ReadEnvelope: %v", err)
	}
	if es.SchemaVersion != "" {
		t.Errorf("schema_version = %q, want empty for bare array", es.SchemaVersion)
	}
}

func TestReadEnvelopeExtra(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "future.json")
	content := `{
  "schema_version": "1.2",
  "extractor": {"name": "x"},
  "fingerprint_v": "abc123",
  "generated_at": "2026-05-30T00:00:00Z",
  "future_key": "preserved",
  "entries": []
}`
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	es, _, err := ReadEnvelope(p)
	if err != nil {
		t.Fatalf("ReadEnvelope: %v", err)
	}
	if es.FingerprintV != "abc123" {
		t.Errorf("fingerprint_v = %q", es.FingerprintV)
	}
	if es.GeneratedAt != "2026-05-30T00:00:00Z" {
		t.Errorf("generated_at = %q", es.GeneratedAt)
	}
	if _, ok := es.Extra["future_key"]; !ok {
		t.Error("Extra missing future_key")
	}
}
