package archaeology

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

// IssueLister fetches the raw JSON payload from `gh issue list --json …`.
// `ghclient.Client.OpenIssues` satisfies the type in production; tests
// inject a deterministic stub.
type IssueLister func(ctx context.Context, dir, repo string, limit int) ([]byte, error)

type ghIssueRaw struct {
	Number    int       `json:"number"`
	Title     string    `json:"title"`
	Labels    []ghLabel `json:"labels"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	Body      string    `json:"body"`
}

type ghLabel struct {
	Name string `json:"name"`
}

// OpenIssues fetches open issues via the supplied IssueLister, filters to
// those updated on or after `since`, and returns the rows sorted by
// (updated_at desc, number asc). Returns the underlying gh / parse error
// unchanged when the call fails.
func OpenIssues(ctx context.Context, list IssueLister, dir, repo string, since time.Time, limit int) ([]Issue, error) {
	raw, err := list(ctx, dir, repo, limit)
	if err != nil {
		return []Issue{}, err
	}
	var decoded []ghIssueRaw
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return []Issue{}, fmt.Errorf("decode gh issue list: %w", err)
	}
	out := make([]Issue, 0, len(decoded))
	for _, r := range decoded {
		if r.UpdatedAt.Before(since) {
			continue
		}
		labels := make([]string, 0, len(r.Labels))
		for _, l := range r.Labels {
			labels = append(labels, l.Name)
		}
		sort.Strings(labels)
		out = append(out, Issue{
			Number:    r.Number,
			Title:     r.Title,
			Labels:    labels,
			CreatedAt: r.CreatedAt,
			UpdatedAt: r.UpdatedAt,
			Body:      r.Body,
		})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if !out[i].UpdatedAt.Equal(out[j].UpdatedAt) {
			return out[i].UpdatedAt.After(out[j].UpdatedAt)
		}
		return out[i].Number < out[j].Number
	})
	return out, nil
}
