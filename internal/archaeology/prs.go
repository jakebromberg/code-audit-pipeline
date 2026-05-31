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
// `since`, when non-zero, narrows the fetch to PRs merged on or after that
// date via gh's `--search "merged:>=YYYY-MM-DD"` filter.
type PRLister func(ctx context.Context, dir, repo string, limit int, since time.Time) ([]byte, error)

// PRDiffFetcher fetches the unified diff for one PR. Returns the diff text.
type PRDiffFetcher func(ctx context.Context, dir, repo string, pr int) (string, error)

// PRFetchResult is the outcome of one MergedPRs call. PRs that succeeded
// land in Rows; per-PR errors are accumulated in PerPRErrors so a single
// transient diff fetch does not abort the entire source.
type PRFetchResult struct {
	Rows        []PR
	PerPRErrors []PerPRError
}

// PerPRError records one PR whose diff fetch or spill failed. The PR is
// excluded from Rows; the surviving PRs are still returned.
type PerPRError struct {
	Number int
	Err    string
}

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
// Per-PR fetch / spill failures are collected in PRFetchResult.PerPRErrors
// rather than aborting the source. Callers (the bundler) surface the count
// via SourceProvenance.Partial so the bundle reports a partial-data
// condition without losing the PRs that did succeed.
//
// `diffDir` must exist; the caller (CLI) is responsible for creation via
// os.MkdirAll. Diffs are written via tmp+rename so a Ctrl-C cannot leave
// a half-written diff referenced from the bundle. `diffPathPrefix` is
// recorded verbatim on each PR's DiffPath, allowing the caller to choose
// a bundle-relative form (e.g., "archaeology/prs/<N>.diff").
func MergedPRs(
	ctx context.Context,
	list PRLister,
	fetchDiff PRDiffFetcher,
	dir, repo string,
	since time.Time, limit int,
	diffDir, diffPathPrefix string,
) (PRFetchResult, error) {
	result := PRFetchResult{Rows: []PR{}}
	raw, err := list(ctx, dir, repo, limit, since)
	if err != nil {
		return result, err
	}
	var decoded []ghPRRaw
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return result, fmt.Errorf("decode gh pr list: %w", err)
	}
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
			diffText, derr := fetchDiff(ctx, dir, repo, r.Number)
			if derr != nil {
				result.PerPRErrors = append(result.PerPRErrors, PerPRError{
					Number: r.Number,
					Err:    derr.Error(),
				})
				continue
			}
			fname := strconv.Itoa(r.Number) + ".diff"
			abs := filepath.Join(diffDir, fname)
			if werr := writeDiffAtomic(abs, diffText); werr != nil {
				result.PerPRErrors = append(result.PerPRErrors, PerPRError{
					Number: r.Number,
					Err:    werr.Error(),
				})
				continue
			}
			pr.DiffPath = filepath.ToSlash(filepath.Join(diffPathPrefix, fname))
			pr.DiffSizeBytes = int64(len(diffText))
		}
		result.Rows = append(result.Rows, pr)
	}
	sort.SliceStable(result.Rows, func(i, j int) bool {
		if !result.Rows[i].MergedAt.Equal(result.Rows[j].MergedAt) {
			return result.Rows[i].MergedAt.After(result.Rows[j].MergedAt)
		}
		return result.Rows[i].Number < result.Rows[j].Number
	})
	return result, nil
}

// writeDiffAtomic writes `body` to `path` via tmp+rename, so a crash or
// concurrent run cannot leave a half-written diff that the bundle still
// references. Matches the same atomic-write contract auditdir.Save and
// cli/archaeology.writeBundle follow.
func writeDiffAtomic(path, body string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename: %w", err)
	}
	return nil
}
