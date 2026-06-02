package cli

import "runtime/debug"

// Version is the code-audit binary's release version. PR 3 ships "0.1.0-skeleton";
// PR 4's goreleaser config replaces this via `-ldflags -X` at link time.
// MUST stay `var`, not `const` — the Go linker's `-X` flag can only override
// package-level variables, not constants, and a const target is silently
// ignored with no build error. See `.goreleaser.yaml`.
var Version = "0.1.0-skeleton"

// readBuildInfo is overridable for tests; production calls debug.ReadBuildInfo.
var readBuildInfo = debug.ReadBuildInfo

// ResolvedVersion returns the most informative version string available.
// Resolution order:
//  1. Version, if a goreleaser `-ldflags -X` injected it at link time.
//  2. BuildInfo.Main.Version, when set by `go install pkg@vX.Y.Z` (not "(devel)").
//  3. The "0.1.0-skeleton" sentinel — an in-tree dev build with no version metadata.
func ResolvedVersion() string {
	if Version != "0.1.0-skeleton" {
		return Version
	}
	if info, ok := readBuildInfo(); ok && info.Main.Version != "" && info.Main.Version != "(devel)" {
		return info.Main.Version
	}
	return Version
}
