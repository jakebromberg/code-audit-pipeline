// Package initstate holds shared constants used by both `code-audit init`
// (under internal/cli) and the //go:generate-time genembed tool. Centralising
// the skip list ensures the binary's `init` walk and the embed-time pruning
// stay in sync; a drift guard in genembed's tests enforces this.
package initstate

// SkipDirs lists directory basenames pruned at every depth when walking
// extractor source trees. The set covers language-specific vendor / build
// caches that balloon the catalog without contributing to extractor source.
//
// SkipDirs is read-only after package init. Concurrent reads are safe; do
// not mutate.
var SkipDirs = map[string]bool{
	"node_modules": true,
	".build":       true,
	".swiftpm":     true,
	"DerivedData":  true,
	"Pods":         true,
	"dist":         true,
	"build":        true,
	"coverage":     true,
}
