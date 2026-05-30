// audit is the binary entry point. Subcommands: extract, query, status.
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
		os.Exit(cli.Extract(ctx, args, stdout))
	case "query":
		os.Exit(cli.Query(ctx, args, stdout, queriesFS))
	case "status":
		os.Exit(cli.Status(args, stdout, queriesFS))
	case "report":
		os.Exit(cli.Report(ctx, args, stdout, queriesFS))
	case "init":
		os.Exit(cli.Init(ctx, args, stdout))
	case "version", "--version", "-v":
		fmt.Fprintln(stdout, cli.Version)
	case "help", "--help", "-h":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "audit: unknown subcommand %q\n", cmd)
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `audit %s — cross-cutting structural analysis

Usage: audit <subcommand> [flags]

Subcommands:
  extract  <name>   Run an extractor (typescript, swift, file-hashes) and cache its output in .audit/.
  query    <name>   Evaluate a query against cached catalogs (embedded gojq).
  status            Show .audit/ state, resolved query/extractor sources, and staleness.
  report            Run every runnable query and write .audit/reports/findings-<date>.md.
  init              Bootstrap ~/.config/audit/ (extractors + queries) from a local source tree.
  version           Print binary version.

See docs/adr/0001..0007.md for the design; plans/pr3-binary-skeleton.md and
plans/pr4-renderers-report-init.md document the implementation arc.
`, cli.Version)
}
