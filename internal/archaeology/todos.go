package archaeology

import (
	"bufio"
	"context"
	"io/fs"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// MTimeFunc returns the last-commit time of a file. Production wires this
// to `git log -1 --format=%ct -- <file>`; tests inject deterministic stubs.
// Returns ok=false when the file is untracked or git is unavailable.
type MTimeFunc func(absPath string) (t time.Time, ok bool)

// markerRegex matches a standalone TODO/FIXME/HACK/XXX token. \b is the
// ASCII word boundary, which (in Go's RE2) treats `_` as a word character
// — so TODOLIST and XXX_PASSWORD correctly do not match.
var markerRegex = regexp.MustCompile(`\b(TODO|FIXME|HACK|XXX)\b`)

// commentIntros are the substrings that introduce a comment. The detector
// finds the leftmost occurrence in a line; if no intro is found, the line
// is treated as code (markers in code are ignored). v1 accepts modest
// false-positive risk for `#` and `--` appearing inside string literals
// (e.g., `s = "#TODO"`) — recall over precision.
//
// `#` is treated as a comment intro for code files (Python, shell, Ruby,
// YAML, TOML). Markdown files are filtered out at the walk layer so a
// `# TODO Tracker` heading is not counted.
var commentIntros = []string{"//", "/*", "<!--", "#", "--"}

// ScanTODOs walks `root` and returns one TODO row per standalone marker
// found in a comment. Files matching the substrate's `is_test` convention
// and Markdown files (where `#` is a heading, not a comment) are skipped
// — TODO inventory targets code maintenance debt, not fixture or doc text.
//
// `mtimes`, when non-nil, supplies per-file age; nil (or a function
// returning ok=false) yields age_days=-1. `now` is used for the age
// computation so tests get deterministic output; pass time.Now() in
// production.
func ScanTODOs(ctx context.Context, root string, mtimes MTimeFunc, now time.Time) ([]TODO, WalkStats, error) {
	if mtimes == nil {
		mtimes = func(string) (time.Time, bool) { return time.Time{}, false }
	}
	ageCache := map[string]int{}
	ageDays := func(absPath string) int {
		if v, ok := ageCache[absPath]; ok {
			return v
		}
		v := -1
		if t, ok := mtimes(absPath); ok {
			v = int(now.Sub(t).Hours() / 24)
			if v < 0 {
				v = 0
			}
		}
		ageCache[absPath] = v
		return v
	}

	out := []TODO{}
	var stats WalkStats
	err := walkSource(ctx, root, &stats, func(absPath, relPath string, _ fs.DirEntry) error {
		if isTestPath(relPath) || isMarkdownFile(relPath) {
			return nil
		}
		bin, berr := isBinaryFile(absPath)
		if berr != nil {
			stats.EntriesSkipped++
			if stats.FirstSkippedPath == "" {
				stats.FirstSkippedPath = absPath
			}
			return nil
		}
		if bin {
			return nil
		}
		f, ferr := os.Open(absPath)
		if ferr != nil {
			stats.EntriesSkipped++
			if stats.FirstSkippedPath == "" {
				stats.FirstSkippedPath = absPath
			}
			return nil
		}
		defer f.Close()
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		lineNum := 0
		for scanner.Scan() {
			lineNum++
			line := scanner.Text()
			start := findCommentStart(line)
			if start < 0 {
				continue
			}
			suffix := line[start:]
			m := markerRegex.FindStringSubmatchIndex(suffix)
			if m == nil {
				continue
			}
			marker := suffix[m[2]:m[3]]
			text := stripMarkerPunctuation(suffix[m[3]:])
			out = append(out, TODO{
				File:    relPath,
				Line:    lineNum,
				Marker:  marker,
				Text:    text,
				AgeDays: ageDays(absPath),
			})
		}
		if serr := scanner.Err(); serr != nil {
			stats.LinesTruncated++
		}
		return nil
	})
	if err != nil {
		return out, stats, err
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].AgeDays != out[j].AgeDays {
			return out[i].AgeDays > out[j].AgeDays
		}
		if out[i].File != out[j].File {
			return out[i].File < out[j].File
		}
		return out[i].Line < out[j].Line
	})
	return out, stats, nil
}

// findCommentStart returns the byte offset of the first character INSIDE
// a comment on `line`, or -1 if the line contains no comment intro.
//
// Two cases:
//
//  1. Block-comment continuation: leading non-whitespace is `*`. The
//     comment payload begins right after the asterisk.
//  2. Otherwise, the leftmost match of `//`, `/*`, `<!--`, `#`, or `--`
//     determines the intro; the payload begins immediately after it.
func findCommentStart(line string) int {
	trimmed := strings.TrimLeft(line, " \t")
	if strings.HasPrefix(trimmed, "*") && !strings.HasPrefix(trimmed, "*/") {
		// Block-comment continuation line: ` * TODO foo`.
		leading := len(line) - len(trimmed)
		return leading + 1
	}
	best := -1
	for _, intro := range commentIntros {
		i := strings.Index(line, intro)
		if i < 0 {
			continue
		}
		end := i + len(intro)
		if best < 0 || i < best {
			best = end
		}
	}
	return best
}

// stripMarkerPunctuation cleans the text that follows the marker token.
// Drops leading `(assignee)` clauses, leading `:`, `-`, and whitespace,
// and trailing block-comment terminators (`*/`, `-->`).
func stripMarkerPunctuation(s string) string {
	if strings.HasPrefix(s, "(") {
		if i := strings.Index(s, ")"); i >= 0 {
			s = s[i+1:]
		}
	}
	s = strings.TrimLeft(s, ": \t-")
	s = strings.TrimRight(s, " \t")
	s = strings.TrimSuffix(s, "*/")
	s = strings.TrimSuffix(s, "-->")
	return strings.TrimRight(s, " \t")
}

// GitMTimes returns an MTimeFunc that runs `git log -1 --format=%ct --
// <file>` to derive each file's last-commit Unix timestamp. The function
// is process-bound to `gitRoot`; pass the audit root.
//
// Each call shells out — callers should let the on-result cache inside
// ScanTODOs amortize repeated lookups per file.
func GitMTimes(ctx context.Context, gitRoot string) MTimeFunc {
	return func(absPath string) (time.Time, bool) {
		cmd := exec.CommandContext(ctx, "git", "log", "-1", "--format=%ct", "--", absPath)
		cmd.Dir = gitRoot
		out, err := cmd.Output()
		if err != nil {
			return time.Time{}, false
		}
		s := strings.TrimSpace(string(out))
		if s == "" {
			return time.Time{}, false
		}
		secs, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return time.Time{}, false
		}
		return time.Unix(secs, 0), true
	}
}
