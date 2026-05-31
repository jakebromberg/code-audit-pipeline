package archaeology

import (
	"bufio"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ErrADRDirMissing indicates `<root>/docs/adr/` does not exist. Callers
// surface this as "skipped" in the bundle's sources block, not a failure.
var ErrADRDirMissing = errors.New("archaeology: docs/adr/ directory not found")

// ReadADRs scans `<root>/docs/adr/` for *.md files and parses each into an
// ADR row. Returns ErrADRDirMissing when the directory does not exist —
// callers should treat that as "no ADRs" rather than a failure.
func ReadADRs(root string) ([]ADR, error) {
	out := []ADR{}
	adrDir := filepath.Join(root, "docs", "adr")
	st, err := os.Stat(adrDir)
	if errors.Is(err, fs.ErrNotExist) {
		return out, ErrADRDirMissing
	}
	if err != nil {
		return out, err
	}
	if !st.IsDir() {
		return out, ErrADRDirMissing
	}

	entries, err := os.ReadDir(adrDir)
	if err != nil {
		return out, err
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		abs := filepath.Join(adrDir, e.Name())
		body, err := os.ReadFile(abs)
		if err != nil {
			continue
		}
		text := string(body)
		out = append(out, ADR{
			File:   filepath.ToSlash(filepath.Join("docs", "adr", e.Name())),
			Title:  parseADRTitle(text, e.Name()),
			Status: parseADRStatus(text),
			Body:   text,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].File < out[j].File })
	return out, nil
}

// parseADRTitle returns the first H1 heading, or the filename stem if none.
func parseADRTitle(text, filename string) string {
	scanner := bufio.NewScanner(strings.NewReader(text))
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "# ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "# "))
		}
	}
	return strings.TrimSuffix(filename, ".md")
}

var (
	// Plain `Status: <v>` declaration, either inside YAML front-matter or
	// in body prose. Same regex; applied to different substrings.
	adrStatusPlain = regexp.MustCompile(`(?im)^status:\s*(\S+)`)
	// Bold inline `**Status:** <v>` — the legacy template form.
	adrStatusBold  = regexp.MustCompile(`(?im)^\*\*status:?\*\*\s*(\S+)`)
	validStatuses = map[string]bool{
		"accepted": true, "proposed": true, "superseded": true, "deprecated": true,
	}
)

// parseADRStatus walks the first 50 lines looking for a status declaration.
//
// Priority order (first match wins):
//  1. YAML front-matter `status:` between `---` delimiters
//  2. Plain `Status: <value>` line in body prose
//  3. Bold `**Status:** <value>` legacy form
//
// Plain beats Bold because Bold is the legacy template — when both are
// present, the more recently-added plain line carries the updated status.
//
// Returns "unknown" when no recognized status is found.
func parseADRStatus(text string) string {
	lines := strings.Split(text, "\n")
	headLines := lines
	if len(headLines) > 50 {
		headLines = headLines[:50]
	}
	head := strings.Join(headLines, "\n")

	if len(headLines) > 0 && strings.TrimSpace(headLines[0]) == "---" {
		// Line-anchored front-matter close: scan for the next line that
		// is exactly `---`. A `---` appearing inside a YAML value (e.g.,
		// inside a description string) does not match here.
		end := -1
		for i := 1; i < len(headLines); i++ {
			if strings.TrimSpace(headLines[i]) == "---" {
				end = i
				break
			}
		}
		if end > 1 {
			fm := strings.Join(headLines[1:end], "\n")
			if m := adrStatusPlain.FindStringSubmatch(fm); m != nil {
				if s := normalizeStatus(m[1]); s != "" {
					return s
				}
			}
		}
	}
	if m := adrStatusPlain.FindStringSubmatch(head); m != nil {
		if s := normalizeStatus(m[1]); s != "" {
			return s
		}
	}
	if m := adrStatusBold.FindStringSubmatch(head); m != nil {
		if s := normalizeStatus(m[1]); s != "" {
			return s
		}
	}
	return "unknown"
}

func normalizeStatus(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = strings.TrimSuffix(s, ".")
	if validStatuses[s] {
		return s
	}
	return ""
}
