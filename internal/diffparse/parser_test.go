package diffparse

import (
	"strings"
	"testing"
)

func TestParseSingleHunkSingleFile(t *testing.T) {
	diff := `diff --git a/foo.go b/foo.go
index 0000001..0000002 100644
--- a/foo.go
+++ b/foo.go
@@ -1,5 +1,5 @@ func bar() {
 line1
-removed-line
+added-line
 line3
 line4
`
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(files) != 1 {
		t.Fatalf("want 1 file, got %d", len(files))
	}
	f := files[0]
	if f.OldPath != "foo.go" || f.NewPath != "foo.go" {
		t.Errorf("paths: old=%q new=%q", f.OldPath, f.NewPath)
	}
	if len(f.Hunks) != 1 {
		t.Fatalf("want 1 hunk, got %d", len(f.Hunks))
	}
	h := f.Hunks[0]
	if h.OldStart != 1 || h.OldLines != 5 || h.NewStart != 1 || h.NewLines != 5 {
		t.Errorf("range: -%d,%d +%d,%d", h.OldStart, h.OldLines, h.NewStart, h.NewLines)
	}
	if h.HeaderContext != "func bar() {" {
		t.Errorf("header context: %q", h.HeaderContext)
	}
	if want := []string{"removed-line"}; !equalSlice(h.Removed, want) {
		t.Errorf("removed: %v want %v", h.Removed, want)
	}
	if want := []string{"added-line"}; !equalSlice(h.Added, want) {
		t.Errorf("added: %v want %v", h.Added, want)
	}
	if want := []string{"line1", "line3", "line4"}; !equalSlice(h.Context, want) {
		t.Errorf("context: %v want %v", h.Context, want)
	}
}

func TestParseMultiHunkMultiFile(t *testing.T) {
	diff := `diff --git a/a.go b/a.go
--- a/a.go
+++ b/a.go
@@ -10 +10 @@
-old A
+new A
@@ -20,2 +20,2 @@
-x
-y
+X
+Y
diff --git a/b.go b/b.go
--- a/b.go
+++ b/b.go
@@ -1,1 +1,2 @@
 keep
+added
`
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(files) != 2 {
		t.Fatalf("want 2 files, got %d", len(files))
	}
	if got := len(files[0].Hunks); got != 2 {
		t.Errorf("file 0: want 2 hunks, got %d", got)
	}
	if got := len(files[1].Hunks); got != 1 {
		t.Errorf("file 1: want 1 hunk, got %d", got)
	}
	// "@@ -10 +10 @@" degenerates to N=1.
	h0 := files[0].Hunks[0]
	if h0.OldLines != 1 || h0.NewLines != 1 {
		t.Errorf("degenerate range: OldLines=%d NewLines=%d want 1/1", h0.OldLines, h0.NewLines)
	}
}

func TestParseNewAndDeletedFile(t *testing.T) {
	diff := `diff --git a/new.go b/new.go
new file mode 100644
--- /dev/null
+++ b/new.go
@@ -0,0 +1,2 @@
+package new
+
diff --git a/old.go b/old.go
deleted file mode 100644
--- a/old.go
+++ /dev/null
@@ -1,2 +0,0 @@
-package old
-
`
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(files) != 2 {
		t.Fatalf("want 2 files, got %d", len(files))
	}
	if got := files[0].Path(); got != "new.go" {
		t.Errorf("new file Path()=%q", got)
	}
	if got := files[1].Path(); got != "old.go" {
		t.Errorf("deleted file Path()=%q (should fall back to OldPath)", got)
	}
}

func TestParseSkipsModeOnlyAndBinary(t *testing.T) {
	diff := `diff --git a/perm.go b/perm.go
old mode 100644
new mode 100755
diff --git a/img.png b/img.png
index 0000001..0000002 100644
Binary files a/img.png and b/img.png differ
diff --git a/real.go b/real.go
--- a/real.go
+++ b/real.go
@@ -1 +1 @@
-a
+b
`
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// Mode-only + binary files have no hunks and are dropped.
	if len(files) != 1 {
		t.Fatalf("want 1 file (only real.go), got %d", len(files))
	}
	if files[0].Path() != "real.go" {
		t.Errorf("path: %q", files[0].Path())
	}
}

func TestParseRejectsMalformedHunkHeader(t *testing.T) {
	diff := `diff --git a/a.go b/a.go
--- a/a.go
+++ b/a.go
@@ broken
-x
`
	_, err := Parse(strings.NewReader(diff))
	if err == nil {
		t.Fatal("want error on broken header")
	}
}

func TestParseRejectsHunkBeforeFileHeader(t *testing.T) {
	diff := `@@ -1 +1 @@
-x
+y
`
	_, err := Parse(strings.NewReader(diff))
	if err == nil {
		t.Fatal("want error on hunk before file header")
	}
}

func TestParseStripsPathPrefixAndTimestamp(t *testing.T) {
	// Some diff producers append a tab + timestamp on --- / +++ lines.
	diff := "diff --git a/foo.go b/foo.go\n" +
		"--- a/foo.go\t2026-05-30 12:00:00.000\n" +
		"+++ b/foo.go\t2026-05-30 12:00:01.000\n" +
		"@@ -1 +1 @@\n" +
		"-a\n" +
		"+b\n"
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if files[0].OldPath != "foo.go" || files[0].NewPath != "foo.go" {
		t.Errorf("paths: old=%q new=%q", files[0].OldPath, files[0].NewPath)
	}
}

func TestParseIgnoresNoNewlineMarker(t *testing.T) {
	diff := `diff --git a/foo.go b/foo.go
--- a/foo.go
+++ b/foo.go
@@ -1 +1 @@
-a
\ No newline at end of file
+b
\ No newline at end of file
`
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	h := files[0].Hunks[0]
	if !equalSlice(h.Removed, []string{"a"}) {
		t.Errorf("removed: %v", h.Removed)
	}
	if !equalSlice(h.Added, []string{"b"}) {
		t.Errorf("added: %v", h.Added)
	}
}

func TestParsePreservesDashDashContentInsideHunk(t *testing.T) {
	// Removed line whose source content is `-- old comment` (Lua/SQL/Haskell
	// `--` comment, YAML frontmatter `--- `) appears in the diff as
	// `--- old comment`. Must be treated as in-hunk removed content, not as
	// a `--- a/file` header.
	diff := "diff --git a/x.lua b/x.lua\n" +
		"--- a/x.lua\n" +
		"+++ b/x.lua\n" +
		"@@ -1,3 +1,3 @@\n" +
		"-- old comment\n" +
		"++ new counter\n" +
		" keep\n"
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(files) != 1 {
		t.Fatalf("want 1 file, got %d", len(files))
	}
	f := files[0]
	if f.OldPath != "x.lua" || f.NewPath != "x.lua" {
		t.Errorf("paths corrupted: old=%q new=%q", f.OldPath, f.NewPath)
	}
	if len(f.Hunks) != 1 {
		t.Fatalf("want 1 hunk, got %d", len(f.Hunks))
	}
	h := f.Hunks[0]
	if !equalSlice(h.Removed, []string{"- old comment"}) {
		t.Errorf("removed: %v (want [\"- old comment\"])", h.Removed)
	}
	if !equalSlice(h.Added, []string{"+ new counter"}) {
		t.Errorf("added: %v (want [\"+ new counter\"])", h.Added)
	}
	if !equalSlice(h.Context, []string{"keep"}) {
		t.Errorf("context: %v (want [\"keep\"])", h.Context)
	}
}

func TestParseFlushesOnNewFileHeaderWithoutDiffGit(t *testing.T) {
	// Raw `diff -u file1 file2` output has no `diff --git` separators —
	// the `--- ` line is the only transition signal. Each file's hunks
	// must land in its own FileDiff, not merge into the last file.
	diff := "--- a/file1.go\n" +
		"+++ b/file1.go\n" +
		"@@ -1 +1 @@\n" +
		"-old1\n" +
		"+new1\n" +
		"--- a/file2.go\n" +
		"+++ b/file2.go\n" +
		"@@ -1 +1 @@\n" +
		"-old2\n" +
		"+new2\n"
	files, err := Parse(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(files) != 2 {
		t.Fatalf("want 2 files, got %d (paths: %v)", len(files), pathsOf(files))
	}
	if files[0].Path() != "file1.go" {
		t.Errorf("file 0 path=%q want file1.go", files[0].Path())
	}
	if files[1].Path() != "file2.go" {
		t.Errorf("file 1 path=%q want file2.go", files[1].Path())
	}
	if !equalSlice(files[0].Hunks[0].Removed, []string{"old1"}) {
		t.Errorf("file 0 removed: %v", files[0].Hunks[0].Removed)
	}
	if !equalSlice(files[1].Hunks[0].Removed, []string{"old2"}) {
		t.Errorf("file 1 removed: %v", files[1].Hunks[0].Removed)
	}
}

func pathsOf(fs []FileDiff) []string {
	out := make([]string, len(fs))
	for i, f := range fs {
		out[i] = f.Path()
	}
	return out
}

func equalSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
