package cli

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
)

// Status implements `audit status`. Returns the process exit code: 0 if all
// catalogs are fresh and the cwd matches meta.json.root; 1 otherwise.
func Status(args []string, out io.Writer, queriesFS fs.FS) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	rootFlag := fs.String("root", "", "audit root (defaults to cwd)")
	queriesDir := fs.String("queries-dir", "", "explicit queries directory")
	extractorsDir := fs.String("extractors-dir", "", "explicit extractors directory")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	root := *rootFlag
	if root == "" {
		cwd, err := os.Getwd()
		if err != nil {
			fmt.Fprintf(out, "audit: getwd: %v\n", err)
			return 2
		}
		root = cwd
	}
	absRoot, _ := filepath.Abs(root)

	c, err := auditdir.Open(absRoot, Version)
	if err != nil {
		fmt.Fprintf(out, "audit: open .audit: %v\n", err)
		return 2
	}
	if _, err := c.RefreshEnvelopes(); err != nil {
		fmt.Fprintf(out, "audit: refresh envelopes: %v\n", err)
		return 2
	}

	auditHome := os.Getenv("AUDIT_HOME")
	homeDir, _ := os.UserHomeDir()
	// Discovery cwd is the binary's actual cwd — the audit-root is where
	// the user's catalogs live, but the extractors/queries directories
	// sit next to the audit-pipeline source tree, not next to user data.
	cwd, _ := os.Getwd()

	qsrc, qerr := discovery.ResolveQueriesDir(discovery.QueryOpts{Flag: *queriesDir, AuditHome: auditHome, CWD: cwd}, queriesFS)
	xpath, xlabel, xerr := discovery.ResolveExtractorsDir(discovery.ExtractorOpts{Flag: *extractorsDir, AuditHome: auditHome, CWD: cwd, HomeDir: homeDir})

	fmt.Fprintf(out, "Audit root:        %s\n", absRoot)
	fmt.Fprintf(out, "Cache:             %s  (audit-version %s)\n", c.Dir, Version)
	if qerr == nil {
		fmt.Fprintf(out, "Queries source:    %s\n", qsrc.Label)
	} else {
		fmt.Fprintf(out, "Queries source:    UNRESOLVED  (%v)\n", qerr)
	}
	if xerr == nil {
		fmt.Fprintf(out, "Extractors source: %s  (%s)\n", xlabel, xpath)
	} else {
		fmt.Fprintf(out, "Extractors source: UNRESOLVED  (%v)\n", xerr)
	}

	rootMismatch := c.Meta().Root != absRoot && c.Meta().Root != ""

	rows, err := c.Status()
	if err != nil {
		fmt.Fprintf(out, "audit: status walk: %v\n", err)
		return 2
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Kind < rows[j].Kind })

	fmt.Fprintln(out, "\nCatalogs cached:")
	if len(rows) == 0 {
		fmt.Fprintln(out, "  (none — run `audit extract <name>` to populate)")
	}
	staleAny := false
	for _, r := range rows {
		marker := "ok"
		if !r.Exists {
			marker = "MISSING"
		} else if r.StaleSourceCount > 0 {
			marker = fmt.Sprintf("%d files newer than catalog", r.StaleSourceCount)
			staleAny = true
		}
		schema := r.SchemaVersion
		if schema == "" {
			schema = "?"
		}
		fmt.Fprintf(out, "  %-22s schema=%-4s %s\n", r.Kind, schema, marker)
	}

	if rootMismatch {
		fmt.Fprintf(out, "\nWarning: meta.json.root=%q differs from cwd=%q\n", c.Meta().Root, absRoot)
	}

	if rootMismatch || qerr != nil || xerr != nil {
		return 1
	}
	if staleAny {
		return 1
	}
	return 0
}
