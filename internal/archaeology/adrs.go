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
	adrDir := filepath.Join(root, "docs", "adr")
	st, err := os.Stat(adrDir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ErrADRDirMissing
	}
	if err != nil {
		return nil, err
	}
	if !st.IsDir() {
		return nil, ErrADRDirMissing
	}

	entries, err := os.ReadDir(adrDir)
	if err != nil {
		return nil, err
	}

	var out []ADR
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
	adrStatusFrontMatter = regexp.MustCompile(`(?im)^status:\s*(\S+)`)
	adrStatusLine        = regexp.MustCompile(`(?im)^status:\s*(\S+)`)
	adrStatusBold        = regexp.MustCompile(`(?im)^\*\*status:?\*\*\s*(\S+)`)
	validStatuses        = map[string]bool{
		"accepted": true, "proposed": true, "superseded": true, "deprecated": true,
	}
)

// parseADRStatus walks the first 50 lines looking for a status declaration.
// Order: front-matter (delimited by ---), then plain "Status: …", then
// "**Status:** …". Returns "unknown" when no recognized status is found.
func parseADRStatus(text string) string {
	lines := strings.SplitN(text, "\n", 100)
	if len(lines) > 50 {
		lines = lines[:50]
	}
	head := strings.Join(lines, "\n")

	if strings.HasPrefix(strings.TrimSpace(text), "---") {
		// Front-matter form: scan only inside the --- ... --- delimiters.
		end := strings.Index(strings.TrimSpace(text)[3:], "---")
		if end > 0 {
			fm := strings.TrimSpace(text)[3 : 3+end]
			if m := adrStatusFrontMatter.FindStringSubmatch(fm); m != nil {
				if s := normalizeStatus(m[1]); s != "" {
					return s
				}
			}
		}
	}
	if m := adrStatusBold.FindStringSubmatch(head); m != nil {
		if s := normalizeStatus(m[1]); s != "" {
			return s
		}
	}
	if m := adrStatusLine.FindStringSubmatch(head); m != nil {
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
