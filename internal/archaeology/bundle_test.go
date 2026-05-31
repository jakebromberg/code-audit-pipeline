package archaeology

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestAssembleOfflineMode runs the bundler with --no-prs and --no-issues
// so no gh calls happen. Verifies the file-system sources populate, the
// gh sources are marked skipped, and overall shape is right.
func TestAssembleOfflineMode(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "CLAUDE.md"), "rules")
	writeFile(t, filepath.Join(root, "docs", "adr", "0001-foo.md"), "# Foo\nStatus: accepted\n")
	writeFile(t, filepath.Join(root, "foo.go"), "// TODO bake bread\n")
	writeFile(t, filepath.Join(root, "Bar.swift"), "@available(*, deprecated)\nfunc bar() {}\n")

	now := time.Date(2026, 5, 30, 12, 0, 0, 0, time.UTC)
	opts := Options{
		Root:       root,
		WindowDays: 90,
		NoIssues:   true,
		NoPRs:      true,
	}
	bundle := Assemble(context.Background(), opts, GHFunctions{}, nil, now, io.Discard)

	if bundle.SchemaVersion != "1" {
		t.Errorf("schema_version=%q want 1", bundle.SchemaVersion)
	}
	if !bundle.GeneratedAt.Equal(now) {
		t.Errorf("generated_at=%v want %v", bundle.GeneratedAt, now)
	}
	if !bundle.Window.Since.Equal(now.AddDate(0, 0, -90)) {
		t.Errorf("window.since=%v", bundle.Window.Since)
	}
	if !bundle.Sources["open_issues"].Skipped {
		t.Error("open_issues not marked skipped")
	}
	if !bundle.Sources["recent_prs"].Skipped {
		t.Error("recent_prs not marked skipped")
	}
	if bundle.Sources["rule_text"].Count != 1 {
		t.Errorf("rule_text count=%d", bundle.Sources["rule_text"].Count)
	}
	if bundle.Sources["adrs"].Count != 1 {
		t.Errorf("adrs count=%d", bundle.Sources["adrs"].Count)
	}
	if bundle.Sources["todos"].Count != 1 {
		t.Errorf("todos count=%d", bundle.Sources["todos"].Count)
	}
	if bundle.Sources["deprecations"].Count != 1 {
		t.Errorf("deprecations count=%d", bundle.Sources["deprecations"].Count)
	}
}

// TestAssembleEmitsEmptyArraysNotNull pins the review finding that
// nil-slice returns from source gatherers marshal as JSON `null`,
// breaking the schema's promise that every section is an array.
func TestAssembleEmitsEmptyArraysNotNull(t *testing.T) {
	root := t.TempDir()
	opts := Options{Root: root, WindowDays: 90, NoIssues: true, NoPRs: true}
	bundle := Assemble(context.Background(), opts, GHFunctions{}, nil, time.Now(), io.Discard)

	data, err := json.Marshal(bundle)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	str := string(data)
	for _, field := range []string{`"open_issues":null`, `"recent_prs":null`, `"todos":null`, `"deprecations":null`, `"adrs":null`, `"rule_text":null`} {
		if strings.Contains(str, field) {
			t.Errorf("bundle contains %q; arrays must marshal as [] when empty", field)
		}
	}
	for _, field := range []string{`"open_issues":[]`, `"recent_prs":[]`, `"todos":[]`, `"deprecations":[]`, `"adrs":[]`, `"rule_text":[]`} {
		if !strings.Contains(str, field) {
			t.Errorf("bundle missing %q", field)
		}
	}
}

// TestAssemblePRDiffFetcherNilCheck pins the review finding that a
// half-wired GHFunctions (PRDiffFetcher left nil while NoPRDiffs is
// false) silently emitted PRs without diffs. The bundler now treats
// it as a wiring failure with a clear error.
func TestAssemblePRDiffFetcherNilCheck(t *testing.T) {
	root := t.TempDir()
	gh := GHFunctions{
		IssueLister: func(ctx context.Context, dir, repo string, limit int) ([]byte, error) { return []byte(`[]`), nil },
		PRLister: func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) {
			return []byte(`[]`), nil
		},
		// PRDiffFetcher intentionally nil.
	}
	opts := Options{Root: root, Repo: "owner/repo", WindowDays: 90, NoTODOs: true, NoDeprecations: true, NoADRs: true, NoRuleText: true}
	bundle := Assemble(context.Background(), opts, gh, nil, time.Now(), io.Discard)
	p := bundle.Sources["recent_prs"]
	if p.OK {
		t.Errorf("want ok=false for nil PRDiffFetcher, got %+v", p)
	}
	if !strings.Contains(p.Error, "PRDiffFetcher") {
		t.Errorf("error should name the missing wiring: %q", p.Error)
	}
}

// TestAssemblePropagatesPRPartialFailures pins the review finding that
// a per-PR diff failure used to abort the whole source. PerPRErrors
// from MergedPRs now flow into SourceProvenance.Partial / Notes while
// surviving PR rows are still emitted.
func TestAssemblePropagatesPRPartialFailures(t *testing.T) {
	root := t.TempDir()
	diffDir := filepath.Join(root, ".audit", "archaeology", "prs")
	if err := os.MkdirAll(diffDir, 0o755); err != nil {
		t.Fatal(err)
	}
	gh := GHFunctions{
		IssueLister: func(ctx context.Context, dir, repo string, limit int) ([]byte, error) { return []byte(`[]`), nil },
		PRLister: func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) {
			return []byte(`[
                {"number":1,"title":"a","mergedAt":"2026-05-10T00:00:00Z","files":[],"body":""},
                {"number":2,"title":"b","mergedAt":"2026-05-15T00:00:00Z","files":[],"body":""}
            ]`), nil
		},
		PRDiffFetcher: func(ctx context.Context, dir, repo string, pr int) (string, error) {
			if pr == 2 {
				return "", errors.New("flaky gh")
			}
			return "DIFF", nil
		},
	}
	opts := Options{Root: root, Repo: "owner/repo", WindowDays: 90, DiffDir: diffDir, DiffPathPrefix: "archaeology/prs",
		NoTODOs: true, NoDeprecations: true, NoADRs: true, NoRuleText: true}
	bundle := Assemble(context.Background(), opts, gh, nil, time.Now(), io.Discard)
	p := bundle.Sources["recent_prs"]
	if !p.OK {
		t.Errorf("partial failure should keep ok=true, got %+v", p)
	}
	if p.Partial != 1 {
		t.Errorf("Partial=%d want 1", p.Partial)
	}
	if !strings.Contains(p.Notes, "#2") {
		t.Errorf("Notes should name the failed PR: %q", p.Notes)
	}
	if len(bundle.RecentPRs) != 1 || bundle.RecentPRs[0].Number != 1 {
		t.Errorf("surviving PR should still be emitted, got %+v", bundle.RecentPRs)
	}
}

func TestAssembleSurfacesIssueListerError(t *testing.T) {
	root := t.TempDir()
	want := errors.New("auth required")
	gh := GHFunctions{
		IssueLister: func(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
			return nil, want
		},
		PRLister: func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) {
			return []byte(`[]`), nil
		},
		PRDiffFetcher: func(ctx context.Context, dir, repo string, pr int) (string, error) { return "", nil },
	}
	opts := Options{Root: root, Repo: "owner/repo", WindowDays: 90, NoTODOs: true, NoDeprecations: true, NoADRs: true, NoRuleText: true}
	bundle := Assemble(context.Background(), opts, gh, nil, time.Now(), io.Discard)
	if bundle.Sources["open_issues"].OK {
		t.Error("want open_issues.ok=false")
	}
	if bundle.Sources["open_issues"].Error == "" {
		t.Error("want non-empty error")
	}
	// Other sources still run normally.
	if !bundle.Sources["recent_prs"].OK {
		t.Error("recent_prs should succeed independently")
	}
}

func TestAssembleADRMissingDirCountsAsZero(t *testing.T) {
	root := t.TempDir()
	// No docs/adr — ReadADRs returns ErrADRDirMissing.
	opts := Options{Root: root, WindowDays: 90, NoIssues: true, NoPRs: true, NoTODOs: true, NoDeprecations: true, NoRuleText: true}
	bundle := Assemble(context.Background(), opts, GHFunctions{}, nil, time.Now(), io.Discard)
	p := bundle.Sources["adrs"]
	if !p.OK {
		t.Errorf("ok=%v want true (missing dir = no rows, not failure)", p.OK)
	}
	if p.Count != 0 || p.Skipped {
		t.Errorf("count=%d skipped=%v", p.Count, p.Skipped)
	}
}

func TestAssembleWritesDiffsWhenEnabled(t *testing.T) {
	root := t.TempDir()
	diffDir := filepath.Join(root, ".audit", "archaeology", "prs")
	if err := os.MkdirAll(diffDir, 0o755); err != nil {
		t.Fatal(err)
	}
	gh := GHFunctions{
		IssueLister: func(ctx context.Context, dir, repo string, limit int) ([]byte, error) { return []byte(`[]`), nil },
		PRLister: func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) {
			return []byte(`[{"number":42,"title":"x","mergedAt":"2026-05-20T00:00:00Z","files":[],"body":""}]`), nil
		},
		PRDiffFetcher: func(ctx context.Context, dir, repo string, pr int) (string, error) { return "DIFF42", nil },
	}
	opts := Options{
		Root:           root,
		Repo:           "owner/repo",
		WindowDays:     90,
		MaxIssues:      1,
		MaxPRs:         1,
		DiffDir:        diffDir,
		DiffPathPrefix: "archaeology/prs",
		NoTODOs:        true, NoDeprecations: true, NoADRs: true, NoRuleText: true,
	}
	now := time.Date(2026, 5, 30, 0, 0, 0, 0, time.UTC)
	bundle := Assemble(context.Background(), opts, gh, nil, now, io.Discard)

	if len(bundle.RecentPRs) != 1 {
		t.Fatalf("want 1 PR, got %d", len(bundle.RecentPRs))
	}
	if bundle.RecentPRs[0].DiffPath != "archaeology/prs/42.diff" {
		t.Errorf("diff_path=%q", bundle.RecentPRs[0].DiffPath)
	}
	data, err := os.ReadFile(filepath.Join(diffDir, "42.diff"))
	if err != nil || string(data) != "DIFF42" {
		t.Errorf("diff body=%q err=%v", data, err)
	}
}
