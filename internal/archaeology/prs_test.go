package archaeology

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMergedPRsFiltersSortsAndSpillsDiffs(t *testing.T) {
	since := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	raw := []byte(`[
        {"number":1,"title":"old","mergedAt":"2026-02-15T00:00:00Z","files":[{"path":"a"}],"body":"old"},
        {"number":228,"title":"newer","mergedAt":"2026-05-20T00:00:00Z","files":[{"path":"c"},{"path":"b"}],"body":"newer"},
        {"number":225,"title":"older","mergedAt":"2026-05-10T00:00:00Z","files":[{"path":"d"}],"body":"older"}
    ]`)
	list := func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) { return raw, nil }
	fetched := map[int]bool{}
	fetchDiff := func(ctx context.Context, dir, repo string, pr int) (string, error) {
		fetched[pr] = true
		return "DIFF-" + dir, nil
	}

	tmp := t.TempDir()
	diffDir := filepath.Join(tmp, "archaeology", "prs")
	if err := os.MkdirAll(diffDir, 0o755); err != nil {
		t.Fatal(err)
	}

	res, err := MergedPRs(context.Background(), list, fetchDiff, "/tmp/foo", "owner/repo", since, 50, diffDir, "archaeology/prs")
	if err != nil {
		t.Fatalf("MergedPRs: %v", err)
	}
	if len(res.Rows) != 2 {
		t.Fatalf("want 2 rows (old filtered), got %d: %+v", len(res.Rows), res.Rows)
	}
	if len(res.PerPRErrors) != 0 {
		t.Errorf("unexpected per-pr errors: %+v", res.PerPRErrors)
	}
	// Sort: newest first, so 228 before 225.
	if res.Rows[0].Number != 228 || res.Rows[1].Number != 225 {
		t.Errorf("sort order: %d, %d", res.Rows[0].Number, res.Rows[1].Number)
	}
	// Files sorted ascending.
	if res.Rows[0].Files[0] != "b" || res.Rows[0].Files[1] != "c" {
		t.Errorf("files not sorted: %v", res.Rows[0].Files)
	}
	// Diffs fetched for surviving rows only.
	if !fetched[228] || !fetched[225] || fetched[1] {
		t.Errorf("fetched=%v want {228,225}", fetched)
	}
	// Diffs spilled to disk; atomic tmp+rename leaves no .tmp sidecar.
	for _, n := range []int{228, 225} {
		data, err := os.ReadFile(filepath.Join(diffDir, formatInt(n)+".diff"))
		if err != nil {
			t.Errorf("diff #%d not written: %v", n, err)
		}
		if string(data) != "DIFF-/tmp/foo" {
			t.Errorf("diff body=%q", data)
		}
		if _, err := os.Stat(filepath.Join(diffDir, formatInt(n)+".diff.tmp")); err == nil {
			t.Errorf("diff #%d left a .tmp file (atomic write should rename)", n)
		}
	}
	// DiffPath is bundle-relative.
	if res.Rows[0].DiffPath != "archaeology/prs/228.diff" {
		t.Errorf("diff_path=%q", res.Rows[0].DiffPath)
	}
	if res.Rows[0].DiffSizeBytes != int64(len("DIFF-/tmp/foo")) {
		t.Errorf("diff_size=%d", res.Rows[0].DiffSizeBytes)
	}
}

func TestMergedPRsSkipsDiffsWhenFetcherNil(t *testing.T) {
	raw := []byte(`[{"number":1,"title":"x","mergedAt":"2026-05-01T00:00:00Z","files":[],"body":""}]`)
	list := func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) { return raw, nil }
	res, err := MergedPRs(context.Background(), list, nil, "", "", time.Time{}, 1, "", "")
	if err != nil {
		t.Fatalf("MergedPRs: %v", err)
	}
	if res.Rows[0].DiffPath != "" {
		t.Errorf("diff_path=%q want empty (no fetcher)", res.Rows[0].DiffPath)
	}
	if res.Rows[0].DiffSizeBytes != 0 {
		t.Errorf("diff_size=%d", res.Rows[0].DiffSizeBytes)
	}
}

// TestMergedPRsPartialFailurePreservesSuccessfulRows is the regression
// pin for the review finding: a single failed per-PR diff fetch used to
// abort the entire source and discard already-fetched PR metadata. Now
// the failed PR is recorded in PerPRErrors and the survivors flow
// through unchanged.
func TestMergedPRsPartialFailurePreservesSuccessfulRows(t *testing.T) {
	raw := []byte(`[
        {"number":1,"title":"a","mergedAt":"2026-05-10T00:00:00Z","files":[],"body":""},
        {"number":2,"title":"b","mergedAt":"2026-05-15T00:00:00Z","files":[],"body":""},
        {"number":3,"title":"c","mergedAt":"2026-05-20T00:00:00Z","files":[],"body":""}
    ]`)
	list := func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) { return raw, nil }
	fetchDiff := func(ctx context.Context, dir, repo string, pr int) (string, error) {
		if pr == 2 {
			return "", errors.New("HTTP 502 Bad Gateway")
		}
		return "DIFF" + formatInt(pr), nil
	}
	diffDir := filepath.Join(t.TempDir(), "prs")
	if err := os.MkdirAll(diffDir, 0o755); err != nil {
		t.Fatal(err)
	}
	res, err := MergedPRs(context.Background(), list, fetchDiff, "", "", time.Time{}, 10, diffDir, "")
	if err != nil {
		t.Fatalf("MergedPRs: %v (a per-PR fail should NOT abort the source)", err)
	}
	if len(res.Rows) != 2 {
		t.Errorf("want 2 surviving rows, got %d: %+v", len(res.Rows), res.Rows)
	}
	if len(res.PerPRErrors) != 1 || res.PerPRErrors[0].Number != 2 {
		t.Errorf("want exactly the #2 failure recorded, got %+v", res.PerPRErrors)
	}
	if !strings.Contains(res.PerPRErrors[0].Err, "502") {
		t.Errorf("error not propagated: %q", res.PerPRErrors[0].Err)
	}
	for _, r := range res.Rows {
		if r.Number == 2 {
			t.Errorf("#2 should be excluded but appeared in Rows")
		}
	}
}

// TestMergedPRsForwardsSinceToLister confirms the search-window value
// flows from the caller through to the gh-call seam, addressing the
// review finding about gh's default createdAt sort dropping
// recently-merged PRs.
func TestMergedPRsForwardsSinceToLister(t *testing.T) {
	want := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	var seenSince time.Time
	list := func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error) {
		seenSince = since
		return []byte(`[]`), nil
	}
	_, err := MergedPRs(context.Background(), list, nil, "", "", want, 1, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !seenSince.Equal(want) {
		t.Errorf("since not forwarded: got %v want %v", seenSince, want)
	}
}

func formatInt(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
