// audit is the binary entry point. Subcommands: extract, status. The query
// subcommand lands in the follow-up PR alongside the gojq engine; main.go
// dispatches a stub message for it here so users see a clear "not yet
// implemented" rather than "unknown subcommand."
//
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
	case "status":
		os.Exit(cli.Status(args, stdout, queriesFS))
	case "query":
		fmt.Fprintln(os.Stderr, "audit: `query` lands in the follow-up PR (gojq engine). Run any pipeline/queries/<name>.jq directly with `jq` until then.")
		os.Exit(2)
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
  status            Show .audit/ state, resolved query/extractor sources, and staleness.
  query    <name>   (Follow-up PR — gojq engine.)
  version           Print binary version.

See plans/pr3-binary-skeleton.md for the full design.
`, cli.Version)
}
