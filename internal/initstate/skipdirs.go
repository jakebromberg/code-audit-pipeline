// Package initstate holds shared constants used by both `code-audit init`
// (under internal/cli) and the //go:generate-time genembed tool. Centralising
// the skip list ensures the binary's `init` walk and the embed-time pruning
// stay in sync; a drift guard in genembed's tests enforces this.
package initstate

// skipDirsCanonical is the canonical set of directory basenames pruned at
// every depth when walking extractor source trees. The set covers
// language-specific vendor / build caches that balloon the catalog without
// contributing to extractor source. Kept unexported so callers cannot mutate
// the package-level state; consume via SkipDirs() (returns a fresh map) or
// IsSkipped(name) (read-only predicate).
var skipDirsCanonical = []string{
	"node_modules",
	".build",
	".swiftpm",
	"DerivedData",
	"Pods",
	"dist",
	"build",
	"coverage",
	// Python: bytecode cache dirs that appear under any module the test
	// suite (or a contributor's local run) has touched. Excluded so the
	// embedded extractor tree doesn't bake host-specific .pyc files into
	// the binary — and so `code-audit init --from <checkout>` doesn't
	// copy them to ~/.config/audit/extractors/python/.
	"__pycache__",
	// Rust: cargo build output under extractors/rust/. Not a dotdir, so it
	// must be named explicitly; excluded so multi-hundred-MB build artifacts
	// are neither embedded in the binary nor copied by `init --from`.
	"target",
}

// SkipDirs returns a freshly allocated copy of the skip-dir set. Each call
// yields an independent map so callers cannot accidentally mutate the
// canonical list shared across packages — the reference-copy footgun in
// `var x = pkg.SomeMap` is impossible by construction.
func SkipDirs() map[string]bool {
	out := make(map[string]bool, len(skipDirsCanonical))
	for _, name := range skipDirsCanonical {
		out[name] = true
	}
	return out
}

// IsSkipped reports whether the directory basename appears in the
// canonical skip set. Read-only; safe to call concurrently.
func IsSkipped(name string) bool {
	for _, s := range skipDirsCanonical {
		if s == name {
			return true
		}
	}
	return false
}
