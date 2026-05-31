package archaeology

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
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

func TestAssembleSurfacesIssueListerError(t *testing.T) {
	root := t.TempDir()
	want := errors.New("auth required")
	gh := GHFunctions{
		IssueLister: func(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
			return nil, want
		},
		PRLister: func(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
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
		PRLister: func(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
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
