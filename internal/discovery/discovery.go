// Package discovery implements the lookup-order chain from ADR-0006:
//
//	1. Explicit flag (--queries-dir / --extractors-dir)
//	2. cwd-relative ./pipeline/queries, ./extractors
//	3. $AUDIT_HOME/{pipeline/queries,extractors}/
//	4. Fallback: bundled embed.FS (queries only), ~/.config/audit/extractors/
//
// cwd-relative wins over $AUDIT_HOME so a contributor working in a repo
// clone picks up their local edits even when $AUDIT_HOME is set (e.g., by
// `audit init` writing to a shell profile). Resolution stops at the first
// hit. The chosen source is returned with a human-readable label so
// `audit status` can surface it.
package discovery

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Source holds the resolved queries directory. Exactly one of Path / FS is
// populated: Path for filesystem-rooted sources, FS for the embedded
// fallback. Label is for human-readable display.
type Source struct {
	Path  string
	FS    fs.FS
	Label string
}

// QueryOpts controls query-source resolution. Empty fields fall through to
// the next step. CWD defaults to os.Getwd() when blank.
type QueryOpts struct {
	Flag     string // value of --queries-dir
	AuditHome string // typically $AUDIT_HOME
	CWD      string
}

// ResolveQueriesDir walks the lookup order and returns the first source that
// contains _canonical.jq (the sentinel that distinguishes the queries dir).
// embedded is the always-available embed.FS rooted at "queries/".
func ResolveQueriesDir(opts QueryOpts, embedded fs.FS) (Source, error) {
	cwd := opts.CWD
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return Source{}, fmt.Errorf("discovery: getwd: %w", err)
		}
	}

	candidates := []struct{ path, label string }{}
	if opts.Flag != "" {
		candidates = append(candidates, struct{ path, label string }{opts.Flag, "--queries-dir " + opts.Flag})
	}
	candidates = append(candidates, struct{ path, label string }{
		filepath.Join(cwd, "pipeline", "queries"),
		"cwd-relative " + filepath.Join(cwd, "pipeline", "queries"),
	})
	if opts.AuditHome != "" {
		candidates = append(candidates, struct{ path, label string }{
			filepath.Join(opts.AuditHome, "pipeline", "queries"),
			"$AUDIT_HOME (" + opts.AuditHome + ")",
		})
	}

	for _, c := range candidates {
		if hasCanonical(c.path) {
			abs, err := filepath.Abs(c.path)
			if err != nil {
				return Source{}, fmt.Errorf("discovery: abs %s: %w", c.path, err)
			}
			return Source{Path: abs, Label: c.label}, nil
		}
	}
	if _, err := fs.Stat(embedded, "_canonical.jq"); err == nil {
		return Source{FS: embedded, Label: "embedded"}, nil
	}
	return Source{}, fmt.Errorf("discovery: no queries directory found (looked in %d candidates and embedded)", len(candidates))
}

// ExtractorOpts controls extractor-source resolution. Same precedence rules.
type ExtractorOpts struct {
	Flag      string
	AuditHome string
	CWD       string
	HomeDir   string // typically os.UserHomeDir(); empty disables the ~/.config fallback.
}

// ResolveExtractorsDir returns (absPath, label, error).
func ResolveExtractorsDir(opts ExtractorOpts) (string, string, error) {
	cwd := opts.CWD
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return "", "", fmt.Errorf("discovery: getwd: %w", err)
		}
	}

	candidates := []struct{ path, label string }{}
	if opts.Flag != "" {
		candidates = append(candidates, struct{ path, label string }{opts.Flag, "--extractors-dir " + opts.Flag})
	}
	candidates = append(candidates, struct{ path, label string }{
		filepath.Join(cwd, "extractors"),
		"cwd-relative " + filepath.Join(cwd, "extractors"),
	})
	if opts.AuditHome != "" {
		candidates = append(candidates, struct{ path, label string }{
			filepath.Join(opts.AuditHome, "extractors"),
			"$AUDIT_HOME (" + opts.AuditHome + ")",
		})
	}
	if opts.HomeDir != "" {
		candidates = append(candidates, struct{ path, label string }{
			filepath.Join(opts.HomeDir, ".config", "audit", "extractors"),
			"~/.config/audit/extractors",
		})
	}

	for _, c := range candidates {
		if dirExists(c.path) {
			abs, err := filepath.Abs(c.path)
			if err != nil {
				return "", "", fmt.Errorf("discovery: abs %s: %w", c.path, err)
			}
			return abs, c.label, nil
		}
	}
	return "", "", fmt.Errorf("discovery: no extractors directory found (run `audit init` to populate ~/.config/audit/)")
}

func hasCanonical(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, "_canonical.jq"))
	return err == nil && !info.IsDir()
}

func dirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}
