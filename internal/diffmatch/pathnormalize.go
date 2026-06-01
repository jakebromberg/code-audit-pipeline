package diffmatch

import "strings"

// NormalizePath canonicalizes a repo-relative path for comparison against
// catalog `.file` entries. Algorithm (in order — order matters):
//
//  1. Strip a trailing `\r` if present (CRLF input from Windows tooling).
//  2. Trim ASCII whitespace from both ends.
//  3. If the result is empty, return "" (no value).
//  4. Replace every `\` with `/` (Windows separator).
//  5. Strip leading `./` segments (`find -print0` and analogues emit them).
//  6. If the result is empty, return "" (no value).
//
// This is the Go port of `normalizePath` at
// extractors/typescript/_lib/walk-predicate.mjs:34. The TS function returns
// `string | null`; this Go version returns `""` for "no value" — both
// callers treat that as "no match." Parity is gated by TestNormalizePath
// in pathnormalize_test.go.
//
// Middle `./` segments (e.g. `a/./b.ts`) are deliberately NOT collapsed
// here; non-canonical paths in catalog rows are caller-responsibility, and
// the TypeScript predicate intentionally rejects them via the dotdir guard
// in `isRelevantPath` — a separate concern from input normalization.
func NormalizePath(s string) string {
	if strings.HasSuffix(s, "\r") {
		s = s[:len(s)-1]
	}
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if strings.ContainsRune(s, '\\') {
		s = strings.ReplaceAll(s, "\\", "/")
	}
	for strings.HasPrefix(s, "./") {
		s = s[2:]
	}
	return s
}
