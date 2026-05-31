package archaeology

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestOpenIssuesFiltersAndSorts(t *testing.T) {
	since := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	raw := []byte(`[
        {"number":42,"title":"old","labels":[{"name":"bug"}],"createdAt":"2025-01-01T00:00:00Z","updatedAt":"2026-02-15T00:00:00Z","body":"old issue"},
        {"number":7,"title":"recent","labels":[{"name":"feature"},{"name":"ui"}],"createdAt":"2026-04-01T00:00:00Z","updatedAt":"2026-04-15T00:00:00Z","body":"new"},
        {"number":9,"title":"newest","labels":[],"createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-29T00:00:00Z","body":"newest"}
    ]`)
	stub := func(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
		if dir != "/tmp/foo" || repo != "owner/repo" || limit != 100 {
			t.Errorf("forwarded: dir=%q repo=%q limit=%d", dir, repo, limit)
		}
		return raw, nil
	}

	got, err := OpenIssues(context.Background(), stub, "/tmp/foo", "owner/repo", since, 100)
	if err != nil {
		t.Fatalf("OpenIssues: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 rows (old filtered out), got %d: %+v", len(got), got)
	}
	if got[0].Number != 9 {
		t.Errorf("first.number=%d want 9 (newest first)", got[0].Number)
	}
	if got[1].Number != 7 {
		t.Errorf("second.number=%d want 7", got[1].Number)
	}
	// Label flattening.
	if len(got[1].Labels) != 2 || got[1].Labels[0] != "feature" || got[1].Labels[1] != "ui" {
		t.Errorf("labels=%v", got[1].Labels)
	}
}

func TestOpenIssuesPropagatesGHError(t *testing.T) {
	want := errors.New("boom")
	stub := func(ctx context.Context, dir, repo string, limit int) ([]byte, error) { return nil, want }
	_, err := OpenIssues(context.Background(), stub, "", "", time.Time{}, 1)
	if !errors.Is(err, want) {
		t.Errorf("want propagated error, got %v", err)
	}
}

func TestOpenIssuesRejectsMalformedJSON(t *testing.T) {
	stub := func(ctx context.Context, dir, repo string, limit int) ([]byte, error) {
		return []byte(`not json`), nil
	}
	_, err := OpenIssues(context.Background(), stub, "", "", time.Time{}, 1)
	if err == nil {
		t.Fatal("want decode error")
	}
}
