package archaeology

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

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
func walkSource(root string, fn func(absPath, relPath string, d fs.DirEntry) error) error {
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if path == root {
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
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		return fn(path, rel, d)
	})
}

// isBinaryFile sniffs the first 8 KiB for a 0x00 byte. UTF-16 / UTF-32
// source files would mis-classify, but those are vanishingly rare in
// audited repos. Returns true when the file contains 0x00 (and is therefore
// considered binary) — callers should skip in that case.
func isBinaryFile(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return true
	}
	defer f.Close()
	var buf [8 * 1024]byte
	n, _ := f.Read(buf[:])
	return bytes.IndexByte(buf[:n], 0x00) >= 0
}
