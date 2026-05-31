package archaeology

import (
	"context"
	"io/fs"
	"os"
	"path"
	"sort"
)

// ReadRuleText walks `root` for every file named CLAUDE.md (respecting the
// shared dotdir / vendor skip rules) and returns one RuleText row per file.
// The scope is "repo" for the root-level file and "package:<last-segment>"
// otherwise (mirroring the package-naming convention the rest of the
// substrate uses). Output is sorted by file path.
func ReadRuleText(ctx context.Context, root string) ([]RuleText, WalkStats, error) {
	out := []RuleText{}
	var stats WalkStats
	err := walkSource(ctx, root, &stats, func(absPath, relPath string, d fs.DirEntry) error {
		if d.Name() != "CLAUDE.md" {
			return nil
		}
		body, err := os.ReadFile(absPath)
		if err != nil {
			return nil
		}
		out = append(out, RuleText{
			File:  relPath,
			Scope: scopeForRulePath(relPath),
			Body:  string(body),
		})
		return nil
	})
	if err != nil {
		return out, stats, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].File < out[j].File })
	return out, stats, nil
}

// scopeForRulePath returns "repo" for the root-level CLAUDE.md and
// "package:<last-segment>" for nested files (e.g., Shared/Core/CLAUDE.md ->
// "package:Core"). Operates on slash-separated relative paths.
func scopeForRulePath(relPath string) string {
	dir := path.Dir(relPath)
	if dir == "." || dir == "" {
		return "repo"
	}
	return "package:" + path.Base(dir)
}
