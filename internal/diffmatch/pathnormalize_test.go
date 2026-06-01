// Path-normalization parity tests against the TypeScript walk-predicate.
//
// PARITY SOURCE: extractors/typescript/_lib/walk-predicate.mjs:34 normalizePath
// PARITY TESTS:  extractors/typescript/test/walk-predicate.test.mjs lines ~131-180
//
// When the TypeScript-side `normalizePath` changes, update this file's case
// table in lockstep. The Go and TS implementations must produce byte-equal
// outputs for every case below — that is the contract this test pins.
//
// The Go return type is `string` (empty string for "unusable input") instead
// of TypeScript's `string | null`. Go's stronger typing makes the type guard
// at the top of the TS function moot. The empty-string return is the Go
// idiom for "no value" and matches what callers (filterRowsByTouched) need:
// an empty path never matches any catalog row's .file.
package diffmatch

import "testing"

func TestNormalizePath(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		// CRLF strip — Windows / git autocrlf inputs.
		{"crlf trailing", "src/foo.ts\r", "src/foo.ts"},
		{"crlf trailing tsx", "src/foo.tsx\r", "src/foo.tsx"},

		// Leading ./ collapse (find -print0 composition).
		{"leading dot-slash", "./src/foo.ts", "src/foo.ts"},
		{"multiple leading dot-slash", "././src/foo.ts", "src/foo.ts"},
		// ./ in the middle is NOT collapsed — non-canonical paths stay as-is.
		// The TypeScript predicate then rejects them via the dotdir guard;
		// our normalizer doesn't enforce that here (it's a separate check
		// the caller may or may not apply), so the middle-./ form stays.
		{"middle dot-slash not collapsed", "a/./foo.ts", "a/./foo.ts"},

		// Windows backslash → forward slash.
		{"backslash sole separator", "src\\foo.ts", "src/foo.ts"},
		{"backslash nested", "src\\sub\\foo.tsx", "src/sub/foo.tsx"},
		{"mixed separators", "src/sub\\foo.ts", "src/sub/foo.ts"},

		// Whitespace trim — both sides.
		{"leading whitespace", " src/foo.ts", "src/foo.ts"},
		{"trailing whitespace", "src/foo.ts ", "src/foo.ts"},
		{"both sides whitespace", "  src/foo.ts  ", "src/foo.ts"},

		// Degenerate / unusable inputs → empty string.
		{"whitespace only", "   ", ""},
		{"empty string", "", ""},
		// Pure ./ collapses to empty (leading ./ collapse + post-collapse empty check).
		{"sole dot-slash", "./", ""},
		{"multiple dot-slashes only", "././", ""},

		// CRLF combines with other normalization stages (order matters).
		{"crlf + leading dot-slash", "./src/foo.ts\r", "src/foo.ts"},
		{"crlf + backslash", "src\\foo.ts\r", "src/foo.ts"},
		{"crlf + whitespace + dot-slash", "  ./src/foo.ts  \r", "src/foo.ts"},
	}

	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			got := NormalizePath(c.in)
			if got != c.want {
				t.Errorf("NormalizePath(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
