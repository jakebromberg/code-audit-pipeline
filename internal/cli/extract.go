package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
	"github.com/jakebromberg/code-audit-pipeline/internal/extractor"
	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// Extract implements `code-audit extract <name> ...`. embeddedExtractorsFS
// is the //go:embed-rooted extractors subtree, used by the auto-extract
// gate when discovery resolves to ~/.config/audit/extractors and that dir
// is empty / stale. Pass nil to disable auto-extract (intended for tests
// that explicitly populate every tier).
func Extract(ctx context.Context, argv []string, out io.Writer, embeddedExtractorsFS fs.FS) int {
	if len(argv) < 1 {
		fmt.Fprintln(out, "usage: code-audit extract <name> [flags]")
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
	includeImports := fs.Bool("include-imports", false, "emit kind:import consumer-edge rows (TypeScript)")
	scanHeader := fs.Bool("scan-header", false, "scan top of each file for \"copied from\"-style phrases (file-hashes)")
	scanMarks := fs.Bool("scan-marks", false, "scan each file for // MARK: section markers (file-hashes)")
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
		fmt.Fprintln(out, "code-audit: --root is required")
		return 2
	}
	absRoot, err := filepath.Abs(*rootFlag)
	if err != nil {
		fmt.Fprintf(out, "code-audit: abs root: %v\n", err)
		return 2
	}

	auditRoot := *auditRootFlag
	if auditRoot == "" {
		auditRoot = absRoot
	}
	auditRootAbs, _ := filepath.Abs(auditRoot)

	cwd, _ := os.Getwd()
	xdir, tier, _, err := discovery.ResolveExtractorsDir(discovery.ExtractorOpts{
		Flag:          *extractorsDir,
		AuditHome:     os.Getenv("AUDIT_HOME"),
		CWD:           cwd,
		HomeDir:       homeDirOrEmpty(),
		XDGConfigHome: os.Getenv("XDG_CONFIG_HOME"),
	})
	if err != nil {
		fmt.Fprintf(out, "code-audit: %v\n", err)
		return 3
	}

	// Auto-extract gate: only fires when the discovery chain fell through
	// to TierConfigDir (~/.config/audit/extractors). Earlier tiers (Flag,
	// Cwd, AuditHome) signal "user is managing source" — the binary never
	// mutates those. Pinned by tests 19, 19a, 19b.
	if tier == discovery.TierConfigDir && embeddedExtractorsFS != nil {
		auditDest := filepath.Dir(xdir)
		if err := ensureExtractor(ctx, name, xdir, auditDest, embeddedExtractorsFS, out); err != nil {
			fmt.Fprintf(out, "code-audit: %v\n", err)
			return 1
		}
	}

	manifestPath := filepath.Join(xdir, name, "manifest.toml")
	m, err := manifest.Parse(manifestPath)
	if err != nil {
		fmt.Fprintf(out, "code-audit: %v\n", err)
		return 2
	}

	cache, err := auditdir.Open(auditRootAbs, Version)
	if err != nil {
		fmt.Fprintf(out, "code-audit: open cache: %v\n", err)
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
		IncludeImports: *includeImports,
		ScanHeader:     *scanHeader,
		ScanMarks:      *scanMarks,
		SetupHint:      m.Runtime.SetupHint,
	}

	catalogsDir := filepath.Join(cache.Dir, "catalogs")
	extractorDir := filepath.Join(xdir, name)

	ran := 0
	var firstErr error
	for _, cmd := range m.Commands {
		if len(only) > 0 && !contains(only, cmd.Catalog) {
			continue
		}
		results, err := extractor.Run(ctx, extractorDir, cmd, args, catalogsDir)
		if err != nil {
			fmt.Fprintf(out, "code-audit: extract %s/%s: %v\n", name, cmd.Catalog, err)
			firstErr = err
			break
		}
		for _, r := range results {
			outBase := filepath.Base(r.OutputPath)
			if err := cache.PutCatalog(r.Catalog, outBase, r.CLIArgs); err != nil {
				fmt.Fprintf(out, "code-audit: cache put %s: %v\n", r.Catalog, err)
				firstErr = err
				break
			}
		}
		if firstErr != nil {
			break
		}
		ran++
	}
	if ran == 0 && firstErr == nil {
		fmt.Fprintf(out, "code-audit: no [[command]] blocks matched (manifest has %d, filter selected 0)\n", len(m.Commands))
		return 2
	}
	// Save what we have even on partial failure — catalog files for completed
	// commands are already on disk, so meta.json must record them too.
	if ran > 0 {
		if err := cache.Save(); err != nil {
			fmt.Fprintf(out, "code-audit: save cache: %v\n", err)
			return 1
		}
	}
	if firstErr != nil {
		return 1
	}
	fmt.Fprintf(out, "code-audit: extract %s ran %d command(s)\n", name, ran)
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
