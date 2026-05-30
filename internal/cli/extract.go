package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
	"github.com/jakebromberg/code-audit-pipeline/internal/extractor"
	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// stringList implements flag.Value for repeated --catalog filters.
type stringList []string

func (s *stringList) String() string     { return fmt.Sprint([]string(*s)) }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

// Extract implements `audit extract <name> ...`.
func Extract(ctx context.Context, argv []string, out io.Writer) int {
	if len(argv) < 1 {
		fmt.Fprintln(out, "usage: audit extract <name> [flags]")
		return 2
	}
	name := argv[0]
	fs := flag.NewFlagSet("extract", flag.ContinueOnError)
	rootFlag := fs.String("root", "", "audited repo root (required)")
	sharedFlag := fs.String("shared", "", "secondary package root")
	touchedFlag := fs.String("touched", "", "touched-in-window file list")
	includeTests := fs.Bool("include-tests", false, "include test files")
	emitRefs := fs.Bool("emit-references", false, "request references sibling")
	emitFiles := fs.Bool("emit-files", false, "request files sibling")
	extensions := fs.String("extensions", "", "comma-separated file extensions")
	minBody := fs.Int("min-body-lines", 0, "function-body line threshold")
	extractorsDir := fs.String("extractors-dir", "", "explicit extractors directory")
	auditRootFlag := fs.String("audit-root", "", "where to place .audit/ (defaults to --root)")
	var only stringList
	fs.Var(&only, "catalog", "only run [[command]] blocks producing this catalog (repeatable)")
	if err := fs.Parse(argv[1:]); err != nil {
		return 2
	}
	if *rootFlag == "" {
		fmt.Fprintln(out, "audit: --root is required")
		return 2
	}
	absRoot, err := filepath.Abs(*rootFlag)
	if err != nil {
		fmt.Fprintf(out, "audit: abs root: %v\n", err)
		return 2
	}

	auditRoot := *auditRootFlag
	if auditRoot == "" {
		auditRoot = absRoot
	}
	auditRootAbs, _ := filepath.Abs(auditRoot)

	cwd, _ := os.Getwd()
	xdir, _, err := discovery.ResolveExtractorsDir(discovery.ExtractorOpts{
		Flag:      *extractorsDir,
		AuditHome: os.Getenv("AUDIT_HOME"),
		CWD:       cwd,
		HomeDir:   homeDirOrEmpty(),
	})
	if err != nil {
		fmt.Fprintf(out, "audit: %v\n", err)
		return 3
	}

	manifestPath := filepath.Join(xdir, name, "manifest.toml")
	m, err := manifest.Parse(manifestPath)
	if err != nil {
		fmt.Fprintf(out, "audit: %v\n", err)
		return 2
	}

	cache, err := auditdir.Open(auditRootAbs, Version)
	if err != nil {
		fmt.Fprintf(out, "audit: open cache: %v\n", err)
		return 2
	}

	args := extractor.Args{
		Root:           absRoot,
		Shared:         abs(*sharedFlag),
		Touched:        abs(*touchedFlag),
		IncludeTests:   *includeTests,
		MinBodyLines:   *minBody,
		Extensions:     *extensions,
		EmitReferences: *emitRefs,
		EmitFiles:      *emitFiles,
	}

	catalogsDir := filepath.Join(cache.Dir, "catalogs")
	extractorDir := filepath.Join(xdir, name)

	ran := 0
	for _, cmd := range m.Commands {
		if len(only) > 0 && !contains(only, cmd.Catalog) {
			continue
		}
		results, err := extractor.Run(ctx, extractorDir, cmd, args, catalogsDir)
		if err != nil {
			fmt.Fprintf(out, "audit: extract %s/%s: %v\n", name, cmd.Catalog, err)
			return 1
		}
		for _, r := range results {
			outBase := filepath.Base(r.OutputPath)
			if err := cache.PutCatalog(r.Catalog, outBase, r.CLIArgs); err != nil {
				fmt.Fprintf(out, "audit: cache put %s: %v\n", r.Catalog, err)
				return 1
			}
		}
		ran++
	}
	if ran == 0 {
		fmt.Fprintf(out, "audit: no [[command]] blocks matched (manifest has %d, filter selected 0)\n", len(m.Commands))
		return 2
	}
	if err := cache.Save(); err != nil {
		fmt.Fprintf(out, "audit: save cache: %v\n", err)
		return 1
	}
	fmt.Fprintf(out, "audit: extract %s ran %d command(s)\n", name, ran)
	return 0
}

func contains(xs []string, x string) bool {
	for _, s := range xs {
		if s == x {
			return true
		}
	}
	return false
}

func abs(p string) string {
	if p == "" {
		return ""
	}
	a, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	return a
}

func homeDirOrEmpty() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return h
}
