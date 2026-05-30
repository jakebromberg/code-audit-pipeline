// Package auditdir manages the per-repo .audit/ cache: meta.json schema,
// atomic writes, .gitignore bootstrap, and source-mtime staleness checks.
// Schema follows ADR-0001 amended by ADR-0007.
package auditdir

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/catalog"
)

const (
	metaFile     = "meta.json"
	catalogsSub  = "catalogs"
	gitignoreSub = ".gitignore"
	dirName      = ".audit"
)

// Meta is the on-disk meta.json shape per ADR-0007.
type Meta struct {
	AuditVersion  string                  `json:"audit_version"`
	LastTouchedAt string                  `json:"last_touched_at"`
	Root          string                  `json:"root"`
	Catalogs      map[string]CatalogEntry `json:"catalogs"`
}

// CatalogEntry records the cached state of one catalog file. EnvelopeSummary
// is a derived cache; authority remains the catalog file itself.
type CatalogEntry struct {
	Path            string                    `json:"path"`
	SourceSHA       string                    `json:"source_sha"`
	EnvelopeSummary *catalog.EnvelopeSummary  `json:"envelope_summary,omitempty"`
	CLIArgs         map[string]any            `json:"cli_args"`
}

// Cache is the in-memory handle on a .audit/ directory.
type Cache struct {
	Root         string // absolute audited-repo root
	Dir          string // absolute path to .audit/ (Root/.audit)
	meta         *Meta
	auditVersion string
}

// Open opens or initializes the .audit/ cache at root/.audit. Creates the
// directory and a fresh meta.json if absent. Auto-appends ".audit/" to
// root/.gitignore on first call.
func Open(root, auditVersion string) (*Cache, error) {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("auditdir: abs: %w", err)
	}
	dir := filepath.Join(absRoot, dirName)
	if err := os.MkdirAll(filepath.Join(dir, catalogsSub), 0o755); err != nil {
		return nil, fmt.Errorf("auditdir: mkdir: %w", err)
	}
	c := &Cache{Root: absRoot, Dir: dir, auditVersion: auditVersion}
	if err := c.load(); err != nil {
		return nil, err
	}
	if err := ensureGitignore(absRoot); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Cache) load() error {
	p := filepath.Join(c.Dir, metaFile)
	data, err := os.ReadFile(p)
	if errors.Is(err, fs.ErrNotExist) {
		c.meta = &Meta{
			AuditVersion: c.auditVersion,
			Root:         c.Root,
			Catalogs:     map[string]CatalogEntry{},
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("auditdir: read meta: %w", err)
	}
	c.meta = &Meta{}
	if err := json.Unmarshal(data, c.meta); err != nil {
		return fmt.Errorf("auditdir: parse meta: %w", err)
	}
	if c.meta.Catalogs == nil {
		c.meta.Catalogs = map[string]CatalogEntry{}
	}
	return nil
}

// Meta returns the live in-memory meta (caller must not mutate without Save).
func (c *Cache) Meta() *Meta { return c.meta }

// PutCatalog records one catalog under the named kind, refreshing the
// envelope_summary from the file on disk and recording the sha256.
// outputFile is the catalogs/<file> name (e.g., "type-catalog.json").
func (c *Cache) PutCatalog(kind, outputFile string, cliArgs map[string]any) error {
	abs := filepath.Join(c.Dir, catalogsSub, outputFile)
	es, sum, err := catalog.ReadEnvelope(abs)
	if err != nil {
		return err
	}
	if cliArgs == nil {
		cliArgs = map[string]any{}
	}
	c.meta.Catalogs[kind] = CatalogEntry{
		Path:            filepath.Join(catalogsSub, outputFile),
		SourceSHA:       sum,
		EnvelopeSummary: es,
		CLIArgs:         cliArgs,
	}
	return nil
}

// CatalogPath returns the absolute path of the named catalog if cached.
func (c *Cache) CatalogPath(kind string) (string, bool) {
	e, ok := c.meta.Catalogs[kind]
	if !ok {
		return "", false
	}
	return filepath.Join(c.Dir, e.Path), true
}

// Save atomically writes meta.json. Updates LastTouchedAt.
func (c *Cache) Save() error {
	c.meta.AuditVersion = c.auditVersion
	c.meta.LastTouchedAt = time.Now().UTC().Format(time.RFC3339)
	c.meta.Root = c.Root
	data, err := json.MarshalIndent(c.meta, "", "  ")
	if err != nil {
		return fmt.Errorf("auditdir: marshal: %w", err)
	}
	data = append(data, '\n')
	p := filepath.Join(c.Dir, metaFile)
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("auditdir: write tmp: %w", err)
	}
	if err := os.Rename(tmp, p); err != nil {
		return fmt.Errorf("auditdir: rename: %w", err)
	}
	return nil
}

// RefreshEnvelopes re-reads each catalog file's envelope head and updates the
// cached envelope_summary when it differs. Returns the number of entries
// refreshed.
func (c *Cache) RefreshEnvelopes() (int, error) {
	refreshed := 0
	for kind, e := range c.meta.Catalogs {
		abs := filepath.Join(c.Dir, e.Path)
		if _, err := os.Stat(abs); errors.Is(err, fs.ErrNotExist) {
			continue
		} else if err != nil {
			return refreshed, fmt.Errorf("auditdir: stat %s: %w", abs, err)
		}
		es, sum, err := catalog.ReadEnvelope(abs)
		if err != nil {
			return refreshed, err
		}
		if sum != e.SourceSHA {
			e.SourceSHA = sum
			e.EnvelopeSummary = es
			c.meta.Catalogs[kind] = e
			refreshed++
		}
	}
	return refreshed, nil
}

// CatalogStatus is one row in `audit status` output.
type CatalogStatus struct {
	Kind             string
	Path             string
	Exists           bool
	StaleSourceCount int
	SchemaVersion    string
	ExtractorBlob    string // human-readable: "name@version"
}

// Status walks each cached catalog and computes per-row metadata.
// Source-mtime staleness is computed against the audit Root, skipping the
// documented dotdir / vendor directories (per docs/pipeline-contract.md).
func (c *Cache) Status() ([]CatalogStatus, error) {
	out := make([]CatalogStatus, 0, len(c.meta.Catalogs))
	for kind, e := range c.meta.Catalogs {
		abs := filepath.Join(c.Dir, e.Path)
		st, err := os.Stat(abs)
		exists := err == nil
		row := CatalogStatus{Kind: kind, Path: abs, Exists: exists}
		if exists {
			if e.EnvelopeSummary != nil {
				row.SchemaVersion = e.EnvelopeSummary.SchemaVersion
				row.ExtractorBlob = string(e.EnvelopeSummary.Extractor)
			}
			row.StaleSourceCount, err = countNewerThan(c.Root, st.ModTime())
			if err != nil {
				return nil, err
			}
		}
		out = append(out, row)
	}
	return out, nil
}

// countNewerThan walks root counting files whose mtime is after t.
// Skip patterns mirror docs/pipeline-contract.md.
func countNewerThan(root string, t time.Time) (int, error) {
	count := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // tolerate transient walk errors
		}
		name := d.Name()
		if d.IsDir() {
			if path == root {
				return nil
			}
			if shouldSkipDir(name) {
				return fs.SkipDir
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		if info.ModTime().After(t) {
			count++
		}
		return nil
	})
	return count, err
}

func shouldSkipDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "node_modules", "dist", "build", "coverage", "DerivedData", "Pods":
		return true
	}
	return false
}

const gitignoreLine = ".audit/"

// ensureGitignore appends ".audit/" to the root .gitignore if not already
// present. Idempotent.
func ensureGitignore(root string) error {
	p := filepath.Join(root, gitignoreSub)
	data, err := os.ReadFile(p)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("auditdir: read .gitignore: %w", err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == gitignoreLine {
			return nil
		}
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("auditdir: append .gitignore: %w", err)
	}
	defer f.Close()
	prefix := ""
	if len(data) > 0 && !strings.HasSuffix(string(data), "\n") {
		prefix = "\n"
	}
	if _, err := f.WriteString(prefix + gitignoreLine + "\n"); err != nil {
		return fmt.Errorf("auditdir: write .gitignore: %w", err)
	}
	return nil
}
