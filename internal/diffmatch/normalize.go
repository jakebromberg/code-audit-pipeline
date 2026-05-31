// Package diffmatch normalizes diff-derived line sets and joins them against
// catalog rows.
//
// Normalization-spec contract (v1 — replicated from the function-catalog
// extractors in lockstep):
//
//  1. Strip block comments matching `/* … */` (non-greedy, multiline).
//  2. Per line: drop everything from the first `//` to end of line.
//  3. Per line: collapse runs of `[ \t]+` to a single space.
//  4. Per line: trim leading/trailing whitespace.
//  5. Drop empty lines.
//  6. (Set semantics) Deduplicate, keeping any one occurrence.
//
// The function-catalog's `body_lines` array is the **sorted-unique** view of
// the same set on both the TS and Swift extractors (see
// extractors/typescript/function-catalog.mjs `bodyFields` and
// extractors/swift/Sources/swift-catalog/Common.swift `normalizeBody`). So a
// diff's removed-line set normalized this way is directly comparable as a
// subset of any `body_lines` array via membership tests.
//
// The body_hash field is intentionally NOT used by find-next-instance:
//   - TS body_hash sha256s the source-order normalized array,
//   - Swift body_hash sha256s the sorted-unique array.
// That asymmetry is a substrate quirk (tracked separately). find-next-instance
// joins on the set, not the hash, so it sidesteps it.
//
// NormalizationVersion is bumped if any of the six rules change. The companion
// parity test (`go test -tags=parity ./internal/diffmatch/...`) verifies the
// Go implementation produces byte-equal sorted-unique output to the
// TypeScript function-catalog extractor on a fixture; when it diverges, the
// version must bump on both sides simultaneously.
package diffmatch

import (
	"regexp"
	"sort"
	"strings"
)

// NormalizationVersion identifies the normalization-spec revision. Bump on
// any rule change; the parity test gates this against the extractors.
const NormalizationVersion = "1"

// blockComment matches `/* … */` across lines, non-greedy.
var blockComment = regexp.MustCompile(`(?s)/\*.*?\*/`)

// wsRun collapses runs of space + tab.
var wsRun = regexp.MustCompile(`[ \t]+`)

// NormalizeText applies the six-step contract to the input text and returns
// the sorted-unique line set.
func NormalizeText(text string) []string {
	text = blockComment.ReplaceAllString(text, "")
	raw := strings.Split(text, "\n")
	out := make([]string, 0, len(raw))
	seen := make(map[string]struct{}, len(raw))
	for _, line := range raw {
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		line = wsRun.ReplaceAllString(line, " ")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if _, dup := seen[line]; dup {
			continue
		}
		seen[line] = struct{}{}
		out = append(out, line)
	}
	sort.Strings(out)
	return out
}

// Normalize applies the contract to a slice of already-split lines. The lines
// must not contain newline bytes — callers pass diff hunk lines, one per slot.
func Normalize(lines []string) []string {
	return NormalizeText(strings.Join(lines, "\n"))
}
