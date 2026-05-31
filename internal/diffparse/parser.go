// Package diffparse parses unified diffs (the format `git diff` and
// `gh pr diff` emit) into per-file hunks. The parser is intentionally minimal
// — it covers the cases find-next-instance needs and rejects formats that
// would silently corrupt the matcher's input.
//
// What it handles:
//   - The standard "diff --git" / "--- a/<path>" / "+++ b/<path>" preamble
//   - Hunk headers of the form "@@ -A,B +C,D @@ <optional context suffix>"
//   - " ", "+", "-" prefixed lines within a hunk
//   - The "\ No newline at end of file" marker (ignored)
//
// What it skips silently (out of scope for find-next-instance):
//   - Rename/copy/permission-only chunks (no removed/added line content)
//   - Binary chunks (signalled by "Binary files <a> and <b> differ")
//   - Submodule chunks
//
// The parser does not attempt to reconstruct file contents; it only records
// the per-hunk removed/added/context line sets. The matcher consumes those
// sets directly.
package diffparse

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// FileDiff is the parsed diff for one file in the unified diff.
type FileDiff struct {
	// OldPath is the path from the "--- a/<path>" line (or "/dev/null" for
	// new files).
	OldPath string
	// NewPath is the path from the "+++ b/<path>" line (or "/dev/null" for
	// deletions).
	NewPath string
	// Hunks lists every hunk in declaration order.
	Hunks []Hunk
}

// Path returns NewPath when it is a real path, otherwise OldPath. This is
// the path that joins against catalog entries — catalogs always reflect the
// committed (post-merge) state, so the "after" path is the right key.
func (f FileDiff) Path() string {
	if f.NewPath != "" && f.NewPath != "/dev/null" {
		return f.NewPath
	}
	return f.OldPath
}

// Hunk is one "@@ … @@" block within a FileDiff.
type Hunk struct {
	OldStart, OldLines int
	NewStart, NewLines int
	// HeaderContext is the text after the second "@@" on the hunk header
	// (often the enclosing function signature). Optional; "" when absent.
	HeaderContext string
	// Removed are the "-" lines with the leading "-" stripped, in source
	// order. Trailing newlines stripped.
	Removed []string
	// Added are the "+" lines with the leading "+" stripped, in source order.
	Added []string
	// Context are the " " (space-prefixed) lines with the prefix stripped.
	Context []string
}

// Parse reads a unified diff from r and returns one FileDiff per file in the
// diff. Returns an error only on malformed hunk headers; unknown preamble
// lines are skipped.
func Parse(r io.Reader) ([]FileDiff, error) {
	sc := bufio.NewScanner(r)
	// Diff lines can be long; raise the default 64KiB buffer.
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	var files []FileDiff
	var cur *FileDiff
	var hunk *Hunk

	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "diff --git "):
			files = appendCurrent(files, cur)
			cur = &FileDiff{}
			hunk = nil
		case strings.HasPrefix(line, "--- "):
			if cur == nil {
				cur = &FileDiff{}
			}
			cur.OldPath = stripDiffPathPrefix(strings.TrimPrefix(line, "--- "))
			hunk = nil
		case strings.HasPrefix(line, "+++ "):
			if cur == nil {
				cur = &FileDiff{}
			}
			cur.NewPath = stripDiffPathPrefix(strings.TrimPrefix(line, "+++ "))
			hunk = nil
		case strings.HasPrefix(line, "@@"):
			if cur == nil {
				return nil, fmt.Errorf("diffparse: hunk header before any file header: %q", line)
			}
			h, err := parseHunkHeader(line)
			if err != nil {
				return nil, err
			}
			cur.Hunks = append(cur.Hunks, h)
			hunk = &cur.Hunks[len(cur.Hunks)-1]
		case hunk != nil && strings.HasPrefix(line, "-"):
			hunk.Removed = append(hunk.Removed, strings.TrimPrefix(line, "-"))
		case hunk != nil && strings.HasPrefix(line, "+"):
			hunk.Added = append(hunk.Added, strings.TrimPrefix(line, "+"))
		case hunk != nil && strings.HasPrefix(line, " "):
			hunk.Context = append(hunk.Context, strings.TrimPrefix(line, " "))
		case strings.HasPrefix(line, `\ `):
			// "\ No newline at end of file" — ignore.
		default:
			// "diff --git" preamble noise (index lines, mode changes, etc.)
			// or stray text between hunks. Safe to skip — we don't reconstruct
			// file content, only catalog the per-hunk line sets.
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("diffparse: scanner: %w", err)
	}
	files = appendCurrent(files, cur)
	return files, nil
}

func appendCurrent(files []FileDiff, cur *FileDiff) []FileDiff {
	if cur == nil {
		return files
	}
	// Drop file entries that produced no hunks (mode-only / rename-only
	// blocks). They carry no removed/added content for the matcher.
	if len(cur.Hunks) == 0 {
		return files
	}
	return append(files, *cur)
}

// stripDiffPathPrefix removes the conventional "a/" or "b/" prefix that
// `git diff` adds. Leaves "/dev/null" untouched. Also strips trailing
// timestamps that some diff producers append after a tab.
func stripDiffPathPrefix(s string) string {
	if i := strings.IndexByte(s, '\t'); i >= 0 {
		s = s[:i]
	}
	s = strings.TrimSpace(s)
	if s == "/dev/null" {
		return s
	}
	if len(s) >= 2 && (strings.HasPrefix(s, "a/") || strings.HasPrefix(s, "b/")) {
		return s[2:]
	}
	return s
}

// parseHunkHeader parses "@@ -A,B +C,D @@ optional-context" where each pair
// "X,Y" may degenerate to "X" (which means Y=1 per unified-diff convention).
func parseHunkHeader(line string) (Hunk, error) {
	// Expect "@@ -OLD +NEW @@" then optional suffix.
	rest := strings.TrimPrefix(line, "@@")
	rest = strings.TrimLeft(rest, " ")
	close := strings.Index(rest, "@@")
	if close < 0 {
		return Hunk{}, fmt.Errorf("diffparse: hunk header missing closing @@: %q", line)
	}
	rangeText := strings.TrimSpace(rest[:close])
	ctx := ""
	if close+2 < len(rest) {
		ctx = strings.TrimLeft(rest[close+2:], " ")
	}
	parts := strings.Fields(rangeText)
	if len(parts) != 2 || !strings.HasPrefix(parts[0], "-") || !strings.HasPrefix(parts[1], "+") {
		return Hunk{}, fmt.Errorf("diffparse: hunk header range malformed: %q", line)
	}
	oldStart, oldLines, err := parseRange(parts[0][1:])
	if err != nil {
		return Hunk{}, fmt.Errorf("diffparse: old range: %w", err)
	}
	newStart, newLines, err := parseRange(parts[1][1:])
	if err != nil {
		return Hunk{}, fmt.Errorf("diffparse: new range: %w", err)
	}
	return Hunk{
		OldStart:      oldStart,
		OldLines:      oldLines,
		NewStart:      newStart,
		NewLines:      newLines,
		HeaderContext: ctx,
	}, nil
}

func parseRange(s string) (int, int, error) {
	if comma := strings.IndexByte(s, ','); comma >= 0 {
		start, err := strconv.Atoi(s[:comma])
		if err != nil {
			return 0, 0, err
		}
		lines, err := strconv.Atoi(s[comma+1:])
		if err != nil {
			return 0, 0, err
		}
		return start, lines, nil
	}
	start, err := strconv.Atoi(s)
	if err != nil {
		return 0, 0, err
	}
	// Per unified-diff convention, missing ",N" means N=1.
	return start, 1, nil
}
