package archaeology

import (
	"context"
	"errors"
	"io"
	"time"
)

// Options carries the resolved flag values that drive a bundle run.
type Options struct {
	Root           string // absolute audit root
	Repo           string // owner/repo; empty disables gh-dependent sources
	WindowDays     int
	MaxIssues      int
	MaxPRs         int
	NoIssues       bool
	NoPRs          bool
	NoTODOs        bool
	NoDeprecations bool
	NoADRs         bool
	NoRuleText     bool
	NoPRDiffs      bool

	// DiffDir is the absolute filesystem path where per-PR diffs are
	// spilled. The CLI is responsible for creating it with os.MkdirAll
	// before calling Assemble.
	DiffDir string
	// DiffPathPrefix is the path prefix recorded on each PR.DiffPath
	// (typically bundle-relative, e.g., "archaeology/prs").
	DiffPathPrefix string

	// GhDir is the working directory passed to gh invocations. Typically
	// the audit root, so gh resolves the active repo when --repo is omitted.
	GhDir string
}

// GHFunctions is the narrow gh seam the bundler needs. Production wires
// it to *ghclient.Client method values; tests inject deterministic stubs.
type GHFunctions struct {
	IssueLister   IssueLister
	PRLister      PRLister
	PRDiffFetcher PRDiffFetcher
}

// Assemble runs each non-skipped source and packages the result into a
// Bundle. Source-level failures populate the sources[] provenance with
// ok=false but do not abort the run — the bundle still emits with the
// successful sources. A nil gh function for a non-skipped gh-dependent
// source is treated as an immediate failure for that source.
//
// `now` is used for `generated_at` and the window's `since` derivation;
// tests pass a fixed value for byte-deterministic output.
//
// `mtimes` supplies per-file TODO age; pass GitMTimes(ctx, root) in
// production or a deterministic stub in tests.
//
// `stderr` receives the per-source summary lines; pass io.Discard to
// silence.
func Assemble(ctx context.Context, opts Options, gh GHFunctions, mtimes MTimeFunc, now time.Time, stderr io.Writer) *Bundle {
	since := now.Add(-time.Duration(opts.WindowDays) * 24 * time.Hour)
	b := &Bundle{
		SchemaVersion: SchemaVersion,
		GeneratedAt:   now,
		Window:        Window{Days: opts.WindowDays, Since: since},
		Repo:          opts.Repo,
		Root:          opts.Root,
		Sources:       map[string]SourceProvenance{},

		OpenIssues:   []Issue{},
		RecentPRs:    []PR{},
		TODOs:        []TODO{},
		Deprecations: []Deprecation{},
		ADRs:         []ADR{},
		RuleText:     []RuleText{},
	}

	b.OpenIssues, b.Sources["open_issues"] = runIssues(ctx, opts, gh, since)
	b.RecentPRs, b.Sources["recent_prs"] = runPRs(ctx, opts, gh, since)
	b.TODOs, b.Sources["todos"] = runTODOs(opts, mtimes, now)
	b.Deprecations, b.Sources["deprecations"] = runDeprecations(opts)
	b.ADRs, b.Sources["adrs"] = runADRs(opts)
	b.RuleText, b.Sources["rule_text"] = runRules(opts)

	return b
}

func runIssues(ctx context.Context, opts Options, gh GHFunctions, since time.Time) ([]Issue, SourceProvenance) {
	if opts.NoIssues {
		return []Issue{}, SourceProvenance{Tool: "gh", OK: true, Skipped: true}
	}
	if gh.IssueLister == nil {
		return []Issue{}, SourceProvenance{Tool: "gh", OK: false, Error: "no IssueLister wired"}
	}
	got, err := OpenIssues(ctx, gh.IssueLister, opts.GhDir, opts.Repo, since, opts.MaxIssues)
	if err != nil {
		return []Issue{}, SourceProvenance{Tool: "gh", OK: false, Error: err.Error()}
	}
	return got, SourceProvenance{Tool: "gh", OK: true, Count: len(got)}
}

func runPRs(ctx context.Context, opts Options, gh GHFunctions, since time.Time) ([]PR, SourceProvenance) {
	if opts.NoPRs {
		return []PR{}, SourceProvenance{Tool: "gh", OK: true, Skipped: true}
	}
	if gh.PRLister == nil {
		return []PR{}, SourceProvenance{Tool: "gh", OK: false, Error: "no PRLister wired"}
	}
	var fetch PRDiffFetcher
	if !opts.NoPRDiffs {
		fetch = gh.PRDiffFetcher
	}
	got, err := MergedPRs(ctx, gh.PRLister, fetch, opts.GhDir, opts.Repo, since, opts.MaxPRs, opts.DiffDir, opts.DiffPathPrefix)
	if err != nil {
		return []PR{}, SourceProvenance{Tool: "gh", OK: false, Error: err.Error()}
	}
	return got, SourceProvenance{Tool: "gh", OK: true, Count: len(got)}
}

func runTODOs(opts Options, mtimes MTimeFunc, now time.Time) ([]TODO, SourceProvenance) {
	if opts.NoTODOs {
		return []TODO{}, SourceProvenance{Tool: "file-walk", OK: true, Skipped: true}
	}
	got, err := ScanTODOs(opts.Root, mtimes, now)
	if err != nil {
		return []TODO{}, SourceProvenance{Tool: "file-walk", OK: false, Error: err.Error()}
	}
	return got, SourceProvenance{Tool: "file-walk", OK: true, Count: len(got)}
}

func runDeprecations(opts Options) ([]Deprecation, SourceProvenance) {
	if opts.NoDeprecations {
		return []Deprecation{}, SourceProvenance{Tool: "file-walk", OK: true, Skipped: true}
	}
	got, err := ScanDeprecations(opts.Root)
	if err != nil {
		return []Deprecation{}, SourceProvenance{Tool: "file-walk", OK: false, Error: err.Error()}
	}
	return got, SourceProvenance{Tool: "file-walk", OK: true, Count: len(got)}
}

func runADRs(opts Options) ([]ADR, SourceProvenance) {
	if opts.NoADRs {
		return []ADR{}, SourceProvenance{Tool: "file-read", OK: true, Skipped: true}
	}
	got, err := ReadADRs(opts.Root)
	if err != nil {
		if errors.Is(err, ErrADRDirMissing) {
			return []ADR{}, SourceProvenance{Tool: "file-read", OK: true, Count: 0}
		}
		return []ADR{}, SourceProvenance{Tool: "file-read", OK: false, Error: err.Error()}
	}
	return got, SourceProvenance{Tool: "file-read", OK: true, Count: len(got)}
}

func runRules(opts Options) ([]RuleText, SourceProvenance) {
	if opts.NoRuleText {
		return []RuleText{}, SourceProvenance{Tool: "file-read", OK: true, Skipped: true}
	}
	got, err := ReadRuleText(opts.Root)
	if err != nil {
		return []RuleText{}, SourceProvenance{Tool: "file-read", OK: false, Error: err.Error()}
	}
	return got, SourceProvenance{Tool: "file-read", OK: true, Count: len(got)}
}
