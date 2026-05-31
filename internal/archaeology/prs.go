package archaeology

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// PRLister fetches the raw JSON payload from `gh pr list --json …`.
type PRLister func(ctx context.Context, dir, repo string, limit int) ([]byte, error)

// PRDiffFetcher fetches the unified diff for one PR. Returns the diff text.
type PRDiffFetcher func(ctx context.Context, dir, repo string, pr int) (string, error)

type ghPRRaw struct {
	Number   int       `json:"number"`
	Title    string    `json:"title"`
	MergedAt time.Time `json:"mergedAt"`
	Files    []ghFile  `json:"files"`
	Body     string    `json:"body"`
}

type ghFile struct {
	Path string `json:"path"`
}

// MergedPRs fetches recently merged PRs via the supplied PRLister, filters
// to those merged on or after `since`, optionally fetches and spills each
// PR's diff to `diffDir`, and returns rows sorted by (merged_at desc,
// number asc). When `fetchDiff` is nil, diff fetches are skipped; the
// returned PRs carry diff_path: "".
//
// `diffDir` must exist; the caller (CLI) is responsible for creation via
// os.MkdirAll. `diffPathPrefix` is recorded verbatim on each PR's
// DiffPath, allowing the caller to choose a bundle-relative form (e.g.,
// "archaeology/prs/<N>.diff").
func MergedPRs(
	ctx context.Context,
	list PRLister,
	fetchDiff PRDiffFetcher,
	dir, repo string,
	since time.Time, limit int,
	diffDir, diffPathPrefix string,
) ([]PR, error) {
	raw, err := list(ctx, dir, repo, limit)
	if err != nil {
		return nil, err
	}
	var decoded []ghPRRaw
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, fmt.Errorf("decode gh pr list: %w", err)
	}
	out := make([]PR, 0, len(decoded))
	for _, r := range decoded {
		if r.MergedAt.Before(since) {
			continue
		}
		files := make([]string, 0, len(r.Files))
		for _, f := range r.Files {
			files = append(files, f.Path)
		}
		sort.Strings(files)
		pr := PR{
			Number:   r.Number,
			Title:    r.Title,
			MergedAt: r.MergedAt,
			Files:    files,
			Body:     r.Body,
		}
		if fetchDiff != nil {
			diffText, err := fetchDiff(ctx, dir, repo, r.Number)
			if err != nil {
				return nil, fmt.Errorf("gh pr diff #%d: %w", r.Number, err)
			}
			fname := strconv.Itoa(r.Number) + ".diff"
			abs := filepath.Join(diffDir, fname)
			if err := os.WriteFile(abs, []byte(diffText), 0o644); err != nil {
				return nil, fmt.Errorf("write pr diff #%d: %w", r.Number, err)
			}
			pr.DiffPath = filepath.ToSlash(filepath.Join(diffPathPrefix, fname))
			pr.DiffSizeBytes = int64(len(diffText))
		}
		out = append(out, pr)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if !out[i].MergedAt.Equal(out[j].MergedAt) {
			return out[i].MergedAt.After(out[j].MergedAt)
		}
		return out[i].Number < out[j].Number
	})
	return out, nil
}
