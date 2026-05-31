// archaeology.go implements `audit archaeology`: gather open issues,
// recent PR diffs, TODO/FIXME inventory, deprecation markers, ADR text,
// and CLAUDE.md rule text into a single per-audit context blob.
//
// See plans/issue-229-archaeology-bundler-plan.md for the design.
package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/archaeology"
	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/ghclient"
)

// Archaeology implements `audit archaeology`.
//
// Exit codes:
//
//	0  success (bundle written)
//	1  runtime failure (disk write, gh failure on required source, JSON marshal)
//	2  usage error
//	3  gh not installed and at least one gh-dependent source enabled
func Archaeology(ctx context.Context, argv []string, stdout io.Writer) int {
	fset := flag.NewFlagSet("archaeology", flag.ContinueOnError)
	rootFlag := fset.String("root", "", "audit root (defaults to cwd)")
	outputFlag := fset.String("output", "", "output path (default: <root>/.audit/archaeology.json)")
	windowDaysFlag := fset.Int("window-days", 90, "recency window for issues and merged PRs")
	repoFlag := fset.String("repo", "", "owner/repo (default: derived from --root via gh repo view)")
	maxPRsFlag := fset.Int("max-prs", 50, "cap on merged PRs to fetch")
	maxIssuesFlag := fset.Int("max-issues", 100, "cap on open issues to fetch")
	noPRsFlag := fset.Bool("no-prs", false, "skip the recent_prs source entirely")
	noIssuesFlag := fset.Bool("no-issues", false, "skip the open_issues source entirely")
	noTODOsFlag := fset.Bool("no-todos", false, "skip the TODO/FIXME walker")
	noDeprecationsFlag := fset.Bool("no-deprecations", false, "skip the deprecation walker")
	noADRsFlag := fset.Bool("no-adrs", false, "skip the docs/adr/ reader")
	noRuleTextFlag := fset.Bool("no-rule-text", false, "skip the CLAUDE.md walker")
	noPRDiffsFlag := fset.Bool("no-pr-diffs", false, "keep recent_prs metadata but skip per-PR diff fetches")
	if err := fset.Parse(argv); err != nil {
		return 2
	}

	root := *rootFlag
	if root == "" {
		cwd, _ := os.Getwd()
		root = cwd
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "audit: resolve --root: %v\n", err)
		return 1
	}

	outputPath := *outputFlag
	if outputPath == "" {
		outputPath = filepath.Join(absRoot, ".audit", "archaeology.json")
	}
	absOutput, err := filepath.Abs(outputPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "audit: resolve --output: %v\n", err)
		return 1
	}

	// Wire auditdir so .audit/ gets appended to the repo's .gitignore on
	// first use. We don't need the cache handle; only the side effect.
	if _, err := auditdir.Open(absRoot, Version); err != nil {
		fmt.Fprintf(os.Stderr, "audit: open .audit/: %v\n", err)
		return 1
	}

	outDir := filepath.Dir(absOutput)
	diffDir := filepath.Join(outDir, "archaeology", "prs")
	if err := os.MkdirAll(diffDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "audit: create diff dir: %v\n", err)
		return 1
	}

	gh := ghclient.New()
	repo := *repoFlag
	if repo == "" && (!*noIssuesFlag || !*noPRsFlag) {
		nm, err := gh.RepoNameWithOwner(ctx, absRoot)
		if err != nil {
			if errors.Is(err, ghclient.ErrGHNotInstalled) {
				fmt.Fprintln(os.Stderr, "audit: gh not installed; pass --repo or set --no-issues --no-prs to run offline")
				return 3
			}
			fmt.Fprintf(os.Stderr, "audit: resolve --repo (pass explicitly): %v\n", err)
			return 1
		}
		repo = nm
	}

	opts := archaeology.Options{
		Root:           absRoot,
		Repo:           repo,
		WindowDays:     *windowDaysFlag,
		MaxIssues:      *maxIssuesFlag,
		MaxPRs:         *maxPRsFlag,
		NoIssues:       *noIssuesFlag,
		NoPRs:          *noPRsFlag,
		NoTODOs:        *noTODOsFlag,
		NoDeprecations: *noDeprecationsFlag,
		NoADRs:         *noADRsFlag,
		NoRuleText:     *noRuleTextFlag,
		NoPRDiffs:      *noPRDiffsFlag,
		DiffDir:        diffDir,
		DiffPathPrefix: "archaeology/prs",
		GhDir:          absRoot,
	}

	funcs := archaeology.GHFunctions{
		IssueLister:   gh.OpenIssues,
		PRLister:      gh.MergedPRs,
		PRDiffFetcher: gh.PRDiff,
	}

	bundle := archaeology.Assemble(ctx, opts, funcs, archaeology.GitMTimes(ctx, absRoot), time.Now().UTC(), os.Stderr)

	if err := writeBundle(absOutput, bundle); err != nil {
		fmt.Fprintf(os.Stderr, "audit: write bundle: %v\n", err)
		return 1
	}

	emitSummary(os.Stderr, bundle, absOutput)
	fmt.Fprintln(stdout, absOutput)
	return 0
}

// writeBundle marshals the bundle and writes it atomically (tmp + rename).
func writeBundle(path string, b *archaeology.Bundle) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(b); err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0o644); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}

func emitSummary(w io.Writer, b *archaeology.Bundle, outputPath string) {
	for _, kind := range []string{"open_issues", "recent_prs", "todos", "deprecations", "adrs", "rule_text"} {
		p := b.Sources[kind]
		switch {
		case p.Skipped:
			fmt.Fprintf(w, "audit archaeology: %-13s = skipped\n", kind)
		case !p.OK:
			fmt.Fprintf(w, "audit archaeology: %-13s = FAILED (%s)\n", kind, p.Error)
		default:
			fmt.Fprintf(w, "audit archaeology: %-13s = %d (%s)\n", kind, p.Count, p.Tool)
		}
	}
	st, err := os.Stat(outputPath)
	if err == nil {
		fmt.Fprintf(w, "audit archaeology: wrote bundle to %s (%d bytes)\n", outputPath, st.Size())
	}
}
