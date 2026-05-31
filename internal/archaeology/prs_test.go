package archaeology

import (
	"context"
	"os"
	"path/filepath"
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
	list := func(ctx context.Context, dir, repo string, limit int) ([]byte, error) { return raw, nil }
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

	got, err := MergedPRs(context.Background(), list, fetchDiff, "/tmp/foo", "owner/repo", since, 50, diffDir, "archaeology/prs")
	if err != nil {
		t.Fatalf("MergedPRs: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 rows (old filtered), got %d: %+v", len(got), got)
	}
	// Sort: newest first, so 228 before 225.
	if got[0].Number != 228 || got[1].Number != 225 {
		t.Errorf("sort order: %d, %d", got[0].Number, got[1].Number)
	}
	// Files sorted ascending.
	if got[0].Files[0] != "b" || got[0].Files[1] != "c" {
		t.Errorf("files not sorted: %v", got[0].Files)
	}
	// Diffs fetched for surviving rows only.
	if !fetched[228] || !fetched[225] || fetched[1] {
		t.Errorf("fetched=%v want {228,225}", fetched)
	}
	// Diffs spilled to disk.
	for _, n := range []int{228, 225} {
		data, err := os.ReadFile(filepath.Join(diffDir, formatInt(n)+".diff"))
		if err != nil {
			t.Errorf("diff #%d not written: %v", n, err)
		}
		if string(data) != "DIFF-/tmp/foo" {
			t.Errorf("diff body=%q", data)
		}
	}
	// DiffPath is bundle-relative.
	if got[0].DiffPath != "archaeology/prs/228.diff" {
		t.Errorf("diff_path=%q", got[0].DiffPath)
	}
	if got[0].DiffSizeBytes != int64(len("DIFF-/tmp/foo")) {
		t.Errorf("diff_size=%d", got[0].DiffSizeBytes)
	}
}

func TestMergedPRsSkipsDiffsWhenFetcherNil(t *testing.T) {
	raw := []byte(`[{"number":1,"title":"x","mergedAt":"2026-05-01T00:00:00Z","files":[],"body":""}]`)
	list := func(ctx context.Context, dir, repo string, limit int) ([]byte, error) { return raw, nil }
	got, err := MergedPRs(context.Background(), list, nil, "", "", time.Time{}, 1, "", "")
	if err != nil {
		t.Fatalf("MergedPRs: %v", err)
	}
	if got[0].DiffPath != "" {
		t.Errorf("diff_path=%q want empty (no fetcher)", got[0].DiffPath)
	}
	if got[0].DiffSizeBytes != 0 {
		t.Errorf("diff_size=%d", got[0].DiffSizeBytes)
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
