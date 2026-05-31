package archaeology

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestScanTODOsMatchesInComments(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "a.go"), strings.Join([]string{
		"package main",
		"",
		"// TODO: cover the empty case",
		"func main() {",
		"\t// FIXME drop this once #1 lands",
		"\tx := 1 // HACK temporary",
		"\t_ = x",
		"\t/* XXX revisit */",
		"}",
	}, "\n"))

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("want 4 rows, got %d: %+v", len(got), got)
	}
	want := []struct {
		marker, text string
		line         int
	}{
		// Sorted by (age desc, file asc, line asc). Age is -1 for all (no
		// git mtime stub) — equal ages sort by file then line ascending.
		{"TODO", "cover the empty case", 3},
		{"FIXME", "drop this once #1 lands", 5},
		{"HACK", "temporary", 6},
		{"XXX", "revisit", 8},
	}
	for i, w := range want {
		if got[i].Marker != w.marker {
			t.Errorf("row %d marker=%q want %q", i, got[i].Marker, w.marker)
		}
		if got[i].Text != w.text {
			t.Errorf("row %d text=%q want %q", i, got[i].Text, w.text)
		}
		if got[i].Line != w.line {
			t.Errorf("row %d line=%d want %d", i, got[i].Line, w.line)
		}
	}
}

func TestScanTODOsIgnoresCodeStringLiterals(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "a.go"), strings.Join([]string{
		"package main",
		"",
		"// real TODO foo",
		"var s = \"this TODO inside a string\"",
		"var t = 'TODO char literal'",
	}, "\n"))

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row (only the //-comment), got %d: %+v", len(got), got)
	}
	if got[0].Text != "foo" {
		t.Errorf("text=%q want foo", got[0].Text)
	}
}

func TestScanTODOsRejectsNonStandaloneTokens(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "a.go"), strings.Join([]string{
		"// TODOLIST should not match",
		"// XXX_PASSWORD should not match",
		"// real TODO match",
	}, "\n"))

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row, got %d: %+v", len(got), got)
	}
	if got[0].Line != 3 {
		t.Errorf("line=%d want 3", got[0].Line)
	}
}

func TestScanTODOsStripsAssigneeAnnotation(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "a.go"), "// TODO(alice): wire this up\n")

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if got[0].Text != "wire this up" {
		t.Errorf("text=%q want 'wire this up'", got[0].Text)
	}
}

func TestScanTODOsHandlesMultipleCommentSyntaxes(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "py.py"), "# TODO python-style\n")
	writeFile(t, filepath.Join(root, "sql.sql"), "-- TODO sql-style\n")
	writeFile(t, filepath.Join(root, "html.html"), "<!-- TODO html-style -->\n")
	writeFile(t, filepath.Join(root, "block.c"), " * TODO block-cont\n")

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("want 4 rows, got %d: %+v", len(got), got)
	}
	wantTexts := map[string]string{
		"block.c":  "block-cont",
		"html.html": "html-style",
		"py.py":    "python-style",
		"sql.sql":  "sql-style",
	}
	for _, r := range got {
		if want, ok := wantTexts[r.File]; ok {
			if r.Text != want {
				t.Errorf("%s text=%q want %q", r.File, r.Text, want)
			}
		}
	}
}

// TestScanTODOsSkipsMarkdownFiles pins the review finding that `#` was
// matching every Markdown heading. `.md` files are now filtered at the
// walk layer so a `# TODO Tracker` README heading does not pollute the
// TODO inventory. Rule-text + ADR sources handle Markdown separately.
func TestScanTODOsSkipsMarkdownFiles(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "README.md"), "# TODO Tracker\n## XXX Roadmap\n")
	writeFile(t, filepath.Join(root, "CLAUDE.md"), "# TODO: remember rules\n")
	writeFile(t, filepath.Join(root, "real.go"), "// TODO real match\n")

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row (markdown filtered), got %d: %+v", len(got), got)
	}
	if got[0].File != "real.go" {
		t.Errorf("file=%q want real.go", got[0].File)
	}
}

// TestScanTODOsSkipsTestPaths pins the review finding that fixture and
// test TODOs were contaminating the maintenance inventory. The
// substrate-wide `is_test` convention is now honored.
func TestScanTODOsSkipsTestPaths(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "fixtures", "broken.go"), "// TODO fixture should be skipped\n")
	writeFile(t, filepath.Join(root, "internal", "foo_test.go"), "// TODO test file should be skipped\n")
	writeFile(t, filepath.Join(root, "tests", "harness.py"), "# TODO test dir skipped\n")
	writeFile(t, filepath.Join(root, "src", "real.go"), "// TODO real match\n")

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row (test paths filtered), got %d: %+v", len(got), got)
	}
	if got[0].File != "src/real.go" {
		t.Errorf("file=%q want src/real.go", got[0].File)
	}
}

func TestScanTODOsSortsByAgeDesc(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "fresh.go"), "// TODO new\n")
	writeFile(t, filepath.Join(root, "stale.go"), "// TODO old\n")
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	mtimes := func(p string) (time.Time, bool) {
		if filepath.Base(p) == "stale.go" {
			return now.Add(-100 * 24 * time.Hour), true
		}
		return now.Add(-10 * 24 * time.Hour), true
	}

	got, _, err := ScanTODOs(context.Background(), root, mtimes, now)
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 rows, got %d", len(got))
	}
	if got[0].File != "stale.go" {
		t.Errorf("first row=%q want stale.go (older = first)", got[0].File)
	}
	if got[0].AgeDays != 100 {
		t.Errorf("stale age=%d want 100", got[0].AgeDays)
	}
	if got[1].AgeDays != 10 {
		t.Errorf("fresh age=%d want 10", got[1].AgeDays)
	}
}

func TestScanTODOsSkipsBinaryFiles(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "real.go"), "// TODO match\n")
	// Binary fixture: contains 0x00 byte in the first 8 KiB.
	binaryContent := "// TODO should-not-match\n\x00\x01\x02"
	writeFile(t, filepath.Join(root, "fake.bin"), binaryContent)

	got, _, err := ScanTODOs(context.Background(), root, nil, time.Now())
	if err != nil {
		t.Fatalf("ScanTODOs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row (binary skipped), got %d: %+v", len(got), got)
	}
	if got[0].File != "real.go" {
		t.Errorf("file=%q want real.go", got[0].File)
	}
}

func TestStripMarkerPunctuation(t *testing.T) {
	cases := []struct{ in, want string }{
		{": foo bar", "foo bar"},
		{" foo bar", "foo bar"},
		{"- foo bar", "foo bar"},
		{"(alice): wire this up", "wire this up"},
		{": close this once #1 lands */", "close this once #1 lands"},
		{" close this once #1 lands -->", "close this once #1 lands"},
	}
	for _, c := range cases {
		got := stripMarkerPunctuation(c.in)
		if got != c.want {
			t.Errorf("strip(%q)=%q want %q", c.in, got, c.want)
		}
	}
}
