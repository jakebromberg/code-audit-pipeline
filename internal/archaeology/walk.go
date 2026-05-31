package archaeology

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// WalkStats records non-fatal events observed during a walk. Callers wire
// these into SourceProvenance.Partial / SourceProvenance.Notes so the
// bundle reports partial-data rather than silently swallowing failures.
type WalkStats struct {
	// EntriesSkipped is the count of files/dirs the walker could not
	// access (permission denied, EIO, broken symlink, race-with-delete).
	EntriesSkipped int
	// FirstSkippedPath is one representative path that errored, for
	// inclusion in the human-readable Notes summary.
	FirstSkippedPath string
	// LinesTruncated is the count of files whose scanner hit
	// bufio.ErrTooLong (single line > the scanner's max-token size).
	LinesTruncated int
}

// shouldSkipDir matches the same convention used by extractors and
// auditdir.shouldSkipDir: any dotdir, plus the common dependency / build /
// IDE directories.
func shouldSkipDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "node_modules", "dist", "build", "coverage", "target", "vendor",
		"Pods", "DerivedData":
		return true
	}
	return false
}

// walkSource walks `root` invoking `fn` for every regular file that is not
// inside a skipped directory. The path passed to `fn` is the absolute path;
// the second argument is the path relative to `root` with forward slashes.
// Errors returned by `fn` propagate.
//
// Per-entry WalkDir errors (permission denied, broken symlink, etc.) are
// recorded into `stats.EntriesSkipped` rather than silently dropped — the
// walk continues, but the caller can surface a partial-data signal via the
// same stats pointer (callbacks can write to it too, e.g. for scanner
// errors). ctx cancellation is honored at every entry; on cancel the walk
// returns ctx.Err() promptly.
func walkSource(ctx context.Context, root string, stats *WalkStats, fn func(absPath, relPath string, d fs.DirEntry) error) error {
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if cerr := ctx.Err(); cerr != nil {
			return cerr
		}
		if err != nil {
			// The error is per-entry, not a global walk failure. Record
			// it and continue — except when WalkDir failed to even open
			// the root, in which case d is nil and we must abort.
			if d == nil {
				return err
			}
			stats.EntriesSkipped++
			if stats.FirstSkippedPath == "" {
				stats.FirstSkippedPath = p
			}
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			if p == root {
				return nil
			}
			if shouldSkipDir(d.Name()) {
				return fs.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr != nil {
			stats.EntriesSkipped++
			if stats.FirstSkippedPath == "" {
				stats.FirstSkippedPath = p
			}
			return nil
		}
		rel = filepath.ToSlash(rel)
		return fn(p, rel, d)
	})
	return err
}

// isBinaryFile sniffs the first 8 KiB for a 0x00 byte. Returns (true, nil)
// when the file is binary, (false, nil) when text, or (false, err) when the
// file could not be opened — the caller distinguishes "skip silently as
// binary" from "record as walk error". UTF-16/UTF-32 source files
// misclassify, but those are vanishingly rare in audited repos.
func isBinaryFile(p string) (bool, error) {
	f, err := os.Open(p)
	if err != nil {
		return false, err
	}
	defer f.Close()
	var buf [8 * 1024]byte
	n, _ := f.Read(buf[:])
	return bytes.IndexByte(buf[:n], 0x00) >= 0, nil
}

// markdownExts is the set of file extensions whose `#` comment intro is
// actually a Markdown heading, not a code comment. TODO and Deprecation
// walkers skip these files entirely (rule_text and ADRs handle the
// Markdown-as-rules signal separately).
var markdownExts = map[string]bool{
	".md":       true,
	".markdown": true,
	".mdown":    true,
	".mkd":      true,
}

// isMarkdownFile returns true when the file's extension is a Markdown
// variant — relevant for the code-comment walkers.
func isMarkdownFile(relPath string) bool {
	return markdownExts[strings.ToLower(path.Ext(relPath))]
}

// testPathPatterns lists the universal directory segments that mark a
// file as test-only (docs/pipeline-contract.md §Test path patterns). The
// substrate-wide convention is that catalog-emitting extractors carry an
// `is_test` flag; the archaeology walkers honor the same convention so
// fixture/test TODOs and deprecations don't contaminate maintenance signal.
var testPathSegments = map[string]bool{
	"tests":        true,
	"test":         true,
	"__tests__":    true,
	"__test__":     true,
	"spec":         true,
	"__mocks__":    true,
	"__fixtures__": true,
	"fixtures":     true,
	"e2e":          true,
	"testdata":     true,
}

// testFilenameSuffixes matches files whose basename declares test intent
// regardless of containing directory (e.g., utils_test.go, foo.test.ts).
var testFilenameSuffixes = []string{
	".test.", ".spec.", ".fixture.", ".fixtures.", ".mock.", ".mocks.",
	"_test.", "_spec.",
}

// isTestPath returns true when the relative path matches any of the
// substrate's test-path conventions. Operates on slash-separated paths.
func isTestPath(relPath string) bool {
	for _, seg := range strings.Split(relPath, "/") {
		if testPathSegments[seg] {
			return true
		}
	}
	base := path.Base(relPath)
	for _, s := range testFilenameSuffixes {
		if strings.Contains(base, s) {
			return true
		}
	}
	return false
}
