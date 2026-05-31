package archaeology

import (
	"bufio"
	"io/fs"
	"os"
	"regexp"
	"sort"
	"strings"
)

var (
	swiftAvailableRe  = regexp.MustCompile(`@available\s*\(\s*\*\s*,\s*deprecated\b`)
	kotlinJavaAnnotRe = regexp.MustCompile(`@Deprecated\b`)
	csharpObsoleteRe  = regexp.MustCompile(`\[\s*Obsolete\b`)
	pythonDecoratorRe = regexp.MustCompile(`^\s*@deprecated\b`)

	// Comment-form deprecation markers. Matched against the post-comment-intro
	// suffix returned by findCommentStart, so the leading comment characters
	// have already been stripped.
	commentDeprecatedRe = regexp.MustCompile(`(?i)^\s*@?deprecated\b[:\s]?\s*(.*?)\s*(?:\*/|-->)?\s*$`)

	// Quoted-string extractor for annotation messages.
	quotedStringRe = regexp.MustCompile(`"([^"]*)"`)

	// Declaration keywords used to extract the deprecated symbol from the
	// next non-blank, non-comment line.
	declRegex = regexp.MustCompile(`\b(?:func|fun|def|class|interface|struct|enum|type|let|var|const|function|protocol|object|record|trait)\s+([A-Za-z_][A-Za-z0-9_]*)`)
)

// ScanDeprecations walks `root` and returns one Deprecation row per
// recognized deprecation marker. Heuristic — v1 favors recall over
// precision. Sort order: (file asc, line asc).
func ScanDeprecations(root string) ([]Deprecation, error) {
	var out []Deprecation
	err := walkSource(root, func(absPath, relPath string, _ fs.DirEntry) error {
		if isBinaryFile(absPath) {
			return nil
		}
		f, err := os.Open(absPath)
		if err != nil {
			return nil
		}
		defer f.Close()

		var lines []string
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			lines = append(lines, scanner.Text())
		}

		for i, line := range lines {
			match := matchDeprecation(line)
			if match == nil {
				continue
			}
			out = append(out, Deprecation{
				File:    relPath,
				Line:    i + 1,
				Kind:    match.kind,
				Symbol:  findFollowingSymbol(lines, i+1),
				Message: match.message,
			})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].File != out[j].File {
			return out[i].File < out[j].File
		}
		return out[i].Line < out[j].Line
	})
	return out, nil
}

type deprecationMatch struct {
	kind    string
	message string
}

// matchDeprecation returns a non-nil match when `line` carries a
// recognized deprecation marker, or nil otherwise.
func matchDeprecation(line string) *deprecationMatch {
	// Annotation forms first — they are unambiguous and need only one
	// regex hit. Message extraction reads the first quoted string on
	// the line, which works for both Swift `message: "..."` and the
	// argument-only forms `@Deprecated("...")` / `[Obsolete("...")]`.
	if swiftAvailableRe.MatchString(line) ||
		kotlinJavaAnnotRe.MatchString(line) ||
		csharpObsoleteRe.MatchString(line) ||
		pythonDecoratorRe.MatchString(line) {
		return &deprecationMatch{kind: "annotation", message: extractQuoted(line)}
	}
	// Comment forms — only count when inside a real comment, so a code
	// line like `let s = "DEPRECATED: foo"` does not match.
	start := findCommentStart(line)
	if start < 0 {
		return nil
	}
	suffix := line[start:]
	if m := commentDeprecatedRe.FindStringSubmatch(suffix); m != nil {
		return &deprecationMatch{kind: "comment", message: strings.TrimSpace(m[1])}
	}
	return nil
}

// extractQuoted returns the contents of the first "..." quoted string on
// the line, or "" if none. Used for annotation-form messages.
func extractQuoted(line string) string {
	m := quotedStringRe.FindStringSubmatch(line)
	if m == nil {
		return ""
	}
	return m[1]
}

// findFollowingSymbol scans up to 5 subsequent lines for the next
// declaration-keyword match. Returns "" if none.
func findFollowingSymbol(lines []string, start int) string {
	end := start + 5
	if end > len(lines) {
		end = len(lines)
	}
	for i := start; i < end; i++ {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		// Skip continued comment / annotation lines so we keep scanning
		// past adjacent doc-comment continuation or stacked annotations.
		if isCommentOrAnnotationLine(line) {
			continue
		}
		if m := declRegex.FindStringSubmatch(line); m != nil {
			return m[1]
		}
		// First non-blank, non-comment, non-annotation line that didn't
		// match a declaration keyword: stop. We don't want to skip over
		// arbitrary code looking for a declaration further down.
		return ""
	}
	return ""
}

func isCommentOrAnnotationLine(trimmed string) bool {
	switch {
	case strings.HasPrefix(trimmed, "//"),
		strings.HasPrefix(trimmed, "/*"),
		strings.HasPrefix(trimmed, "*"),
		strings.HasPrefix(trimmed, "#"),
		strings.HasPrefix(trimmed, "<!--"),
		strings.HasPrefix(trimmed, "@"),
		strings.HasPrefix(trimmed, "["):
		return true
	}
	return false
}
