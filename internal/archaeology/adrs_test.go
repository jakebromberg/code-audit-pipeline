package archaeology

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestReadADRsMissingDir(t *testing.T) {
	root := t.TempDir()
	_, err := ReadADRs(root)
	if !errors.Is(err, ErrADRDirMissing) {
		t.Errorf("want ErrADRDirMissing, got %v", err)
	}
}

func TestReadADRsEmptyDir(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docs", "adr"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("want 0 rows, got %d", len(got))
	}
}

func TestReadADRsParsesFrontMatterStatus(t *testing.T) {
	root := t.TempDir()
	body := "---\nstatus: accepted\ndate: 2026-01-15\n---\n\n# ADR 0001: Foo\n\nDecision body.\n"
	writeFile(t, filepath.Join(root, "docs", "adr", "0001-foo.md"), body)

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row, got %d", len(got))
	}
	a := got[0]
	if a.File != "docs/adr/0001-foo.md" {
		t.Errorf("file=%q", a.File)
	}
	if a.Title != "ADR 0001: Foo" {
		t.Errorf("title=%q", a.Title)
	}
	if a.Status != "accepted" {
		t.Errorf("status=%q want accepted", a.Status)
	}
}

func TestReadADRsParsesInlineStatusLine(t *testing.T) {
	root := t.TempDir()
	body := "# ADR 0002: Bar\n\nStatus: proposed\n\nContext...\n"
	writeFile(t, filepath.Join(root, "docs", "adr", "0002-bar.md"), body)

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if got[0].Status != "proposed" {
		t.Errorf("status=%q want proposed", got[0].Status)
	}
}

func TestReadADRsParsesBoldStatus(t *testing.T) {
	root := t.TempDir()
	body := "# ADR 0003: Baz\n\n**Status:** superseded\n"
	writeFile(t, filepath.Join(root, "docs", "adr", "0003-baz.md"), body)

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if got[0].Status != "superseded" {
		t.Errorf("status=%q want superseded", got[0].Status)
	}
}

func TestReadADRsFallsBackToUnknownStatus(t *testing.T) {
	root := t.TempDir()
	body := "# ADR 0004: Quux\n\nThis ADR has no status marker.\n"
	writeFile(t, filepath.Join(root, "docs", "adr", "0004-quux.md"), body)

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if got[0].Status != "unknown" {
		t.Errorf("status=%q want unknown", got[0].Status)
	}
}

func TestReadADRsFallsBackToFilenameStemTitle(t *testing.T) {
	root := t.TempDir()
	body := "No heading here.\n"
	writeFile(t, filepath.Join(root, "docs", "adr", "0005-no-heading.md"), body)

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if got[0].Title != "0005-no-heading" {
		t.Errorf("title=%q want 0005-no-heading", got[0].Title)
	}
}

// TestReadADRsPlainBeatsBold pins the review finding that the
// docstring's documented priority (front-matter, plain Status:, bold
// **Status:**) didn't match the code, which checked bold before plain.
// When both bold and plain are present, the more recently-added plain
// line carries the updated status — so plain wins.
func TestReadADRsPlainBeatsBold(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "docs", "adr", "0010-mixed.md"),
		"# ADR 0010: Mixed\n\n**Status:** proposed\n\nStatus: accepted\n")

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if got[0].Status != "accepted" {
		t.Errorf("status=%q want accepted (plain beats bold)", got[0].Status)
	}
}

// TestReadADRsFrontMatterCloseIsLineAnchored pins the review finding
// that `strings.Index(..., "---")` would truncate the front-matter
// scope whenever a `---` appeared inside a YAML value, causing the
// status to silently fall through to `unknown`.
func TestReadADRsFrontMatterCloseIsLineAnchored(t *testing.T) {
	root := t.TempDir()
	body := "---\ndescription: handles --- inline separators in values\nstatus: accepted\n---\n\n# ADR with embedded dashes\n"
	writeFile(t, filepath.Join(root, "docs", "adr", "0011-dashes.md"), body)

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	if got[0].Status != "accepted" {
		t.Errorf("status=%q want accepted (front-matter close must be line-anchored)", got[0].Status)
	}
}

func TestReadADRsSortsByFile(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "docs", "adr", "0002-b.md"), "# B\n")
	writeFile(t, filepath.Join(root, "docs", "adr", "0001-a.md"), "# A\n")
	writeFile(t, filepath.Join(root, "docs", "adr", "0003-c.md"), "# C\n")

	got, err := ReadADRs(root)
	if err != nil {
		t.Fatalf("ReadADRs: %v", err)
	}
	want := []string{"docs/adr/0001-a.md", "docs/adr/0002-b.md", "docs/adr/0003-c.md"}
	for i, w := range want {
		if got[i].File != w {
			t.Errorf("row %d file=%q want %q", i, got[i].File, w)
		}
	}
}

