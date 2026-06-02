// code-audit is the binary entry point. Subcommands: extract, query, status.
// See plans/pr3-binary-skeleton.md.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/jakebromberg/code-audit-pipeline/internal/cli"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	cmd := os.Args[1]
	args := os.Args[2:]
	stdout := os.Stdout
	queriesFS := embeddedQueries()

	switch cmd {
	case "extract":
		os.Exit(cli.Extract(ctx, args, stdout, embeddedExtractors()))
	case "query":
		os.Exit(cli.Query(ctx, args, stdout, queriesFS))
	case "status":
		os.Exit(cli.Status(args, stdout, queriesFS))
	case "report":
		os.Exit(cli.Report(ctx, args, stdout, queriesFS))
	case "init":
		os.Exit(cli.Init(ctx, args, stdout, embeddedInitSubtrees()))
	case "doctor":
		os.Exit(cli.Doctor(args, stdout))
	case "find-next-instance":
		os.Exit(cli.FindNextInstance(ctx, args, stdout))
	case "archaeology":
		os.Exit(cli.Archaeology(ctx, args, stdout))
	case "version", "--version", "-v":
		fmt.Fprintln(stdout, cli.ResolvedVersion())
	case "help", "--help", "-h":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "code-audit: unknown subcommand %q\n", cmd)
		usage()
		os.Exit(2)
	}
}

// embeddedInitSubtrees composes the [extractors, pipeline/queries] subtree
// list that `code-audit init` uses when no --from is given. Each entry
// carries an embed-backed fs.FS; the cli package stays decoupled from the
// embed.FS values that only the main package can see.
func embeddedInitSubtrees() []cli.SubtreeSrc {
	return []cli.SubtreeSrc{
		{RelPath: "extractors", FS: embeddedExtractors(), Embedded: true},
		{RelPath: "pipeline/queries", FS: embeddedQueries(), Embedded: true},
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `code-audit %s — cross-cutting structural analysis

Usage: code-audit <subcommand> [flags]

Subcommands:
  extract  <name>   Run an extractor (typescript, swift, file-hashes) and cache its output in .audit/.
  query    <name>   Evaluate a query against cached catalogs (embedded gojq).
  status            Show .audit/ state, resolved query/extractor sources, and staleness.
  report            Run every runnable query and write .audit/reports/findings-<date>.md.
  init              Bootstrap ~/.config/audit/ (extractors + queries) from a local source tree.
  doctor            Diagnose bootstrap state, runtime tool availability, and per-extractor manifest health.
  find-next-instance  Given a closed PR, surface other catalog members matching its before-shape.
  archaeology       Gather issues, recent PR diffs, TODOs, deprecations, ADRs, and CLAUDE.md into a context blob.
  version           Print binary version.

See docs/adr/0001..0007.md for the design; plans/pr3-binary-skeleton.md and
plans/pr4-renderers-report-init.md document the implementation arc.
`, cli.ResolvedVersion())
}
