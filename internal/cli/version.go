package cli

// Version is the code-audit binary's release version. PR 3 ships "0.1.0-skeleton";
// PR 4's goreleaser config replaces this via `-ldflags -X` at link time.
// MUST stay `var`, not `const` — the Go linker's `-X` flag can only override
// package-level variables, not constants, and a const target is silently
// ignored with no build error. See `.goreleaser.yaml`.
var Version = "0.1.0-skeleton"
