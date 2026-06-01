package cli

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
)

// Status implements `code-audit status`. Returns the process exit code: 0 if all
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
			fmt.Fprintf(out, "code-audit: getwd: %v\n", err)
			return 2
		}
		root = cwd
	}
	absRoot, _ := filepath.Abs(root)

	c, err := auditdir.Open(absRoot, Version)
	if err != nil {
		fmt.Fprintf(out, "code-audit: open .audit: %v\n", err)
		return 2
	}
	if _, err := c.RefreshEnvelopes(); err != nil {
		fmt.Fprintf(out, "code-audit: refresh envelopes: %v\n", err)
		return 2
	}

	auditHome := os.Getenv("AUDIT_HOME")
	homeDir, _ := os.UserHomeDir()
	// Discovery cwd is the binary's actual cwd — the audit-root is where
	// the user's catalogs live, but the extractors/queries directories
	// sit next to the audit-pipeline source tree, not next to user data.
	cwd, _ := os.Getwd()

	qsrc, qerr := discovery.ResolveQueriesDir(discovery.QueryOpts{Flag: *queriesDir, AuditHome: auditHome, CWD: cwd}, queriesFS)
	xpath, _, xlabel, xerr := discovery.ResolveExtractorsDir(discovery.ExtractorOpts{
		Flag:          *extractorsDir,
		AuditHome:     auditHome,
		CWD:           cwd,
		HomeDir:       homeDir,
		XDGConfigHome: os.Getenv("XDG_CONFIG_HOME"),
	})

	fmt.Fprintf(out, "Audit root:        %s\n", absRoot)
	fmt.Fprintf(out, "Cache:             %s  (audit-version %s)\n", c.Dir, Version)
	if qerr == nil {
		fmt.Fprintf(out, "Queries source:    %s\n", qsrc.Label)
	} else {
		fmt.Fprintf(out, "Queries source:    UNRESOLVED  (%v)\n", qerr)
	}
	// Discovery's TierConfigDir fallback returns the would-be path even
	// when the directory doesn't yet exist (so `extract` can auto-extract
	// into it). Status should not paint a fresh-install pre-extract
	// environment as healthy — re-stat xpath and downgrade to PENDING
	// when the path is missing.
	xpathMissing := false
	if xerr == nil {
		if info, statErr := os.Stat(xpath); statErr != nil || !info.IsDir() {
			xpathMissing = true
		}
	}
	switch {
	case xerr != nil:
		fmt.Fprintf(out, "Extractors source: UNRESOLVED  (%v)\n", xerr)
	case xpathMissing:
		fmt.Fprintf(out, "Extractors source: PENDING  %s  (will be created on first `code-audit extract`)\n", xpath)
	default:
		fmt.Fprintf(out, "Extractors source: %s  (%s)\n", xlabel, xpath)
	}

	rootMismatch := c.Meta().Root != absRoot && c.Meta().Root != ""

	rows, err := c.Status()
	if err != nil {
		fmt.Fprintf(out, "code-audit: status walk: %v\n", err)
		return 2
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Kind < rows[j].Kind })

	fmt.Fprintln(out, "\nCatalogs cached:")
	if len(rows) == 0 {
		fmt.Fprintln(out, "  (none — run `code-audit extract <name>` to populate)")
	}
	staleAny := false
	for _, r := range rows {
		marker := "ok"
		if !r.Exists {
			marker = "MISSING"
			staleAny = true
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

	bootstrapDest := defaultDest()
	if bootstrapDest != "" {
		bootstrapState, _ := loadState(bootstrapDest)
		renderExtractorBootstrapState(out, bootstrapState, bootstrapDest, homeDir)
	}

	if rootMismatch || qerr != nil || xerr != nil {
		return 1
	}
	if staleAny {
		return 1
	}
	return 0
}

// renderExtractorBootstrapState prints a per-extractor block sourced from
// state.Extractors. The block is suppressed when state is nil or has no
// extractor entries (the case for users who only ever ran cwd-local
// extractors and never invoked `init`/auto-extract).
func renderExtractorBootstrapState(out io.Writer, state *InitState, dest, homeDir string) {
	if state == nil || len(state.Extractors) == 0 {
		return
	}
	names := make([]string, 0, len(state.Extractors))
	for n := range state.Extractors {
		names = append(names, n)
	}
	sort.Strings(names)

	sourceLabel := state.SourceRepoRoot
	if sourceLabel == "" {
		sourceLabel = "?"
	}
	fmt.Fprintln(out, "\nExtractors:")
	for _, n := range names {
		es := state.Extractors[n]
		extPath := tildify(filepath.Join(dest, "extractors", n), homeDir)
		fmt.Fprintf(out, "  %s: %s  [%s]\n", n, extPath, sourceLabel)
		switch es.BootstrapStatus {
		case BootstrapOK:
			when := "?"
			if es.BootstrappedAt != nil {
				when = es.BootstrappedAt.UTC().Format(time.RFC3339)
			}
			fmt.Fprintf(out, "    bootstrap: ok (%s)\n", when)
		case BootstrapFailed:
			firstLine := strings.SplitN(strings.TrimSpace(es.LastError), "\n", 2)[0]
			if firstLine == "" {
				firstLine = "(no error captured)"
			}
			fmt.Fprintf(out, "    bootstrap: failed: %s\n", firstLine)
		case BootstrapNA:
			fmt.Fprintln(out, "    bootstrap: n/a (no [runtime].bootstrap declared)")
		case BootstrapPending, "":
			fmt.Fprintln(out, "    bootstrap: pending (will run on next `extract`)")
		default:
			fmt.Fprintf(out, "    bootstrap: %s\n", es.BootstrapStatus)
		}
	}
}

// tildify replaces a leading home-dir prefix with "~" so status output is
// readable without leaking the user's full home path.
func tildify(p, home string) string {
	if home == "" {
		return p
	}
	if p == home {
		return "~"
	}
	if strings.HasPrefix(p, home+string(filepath.Separator)) {
		return "~" + p[len(home):]
	}
	return p
}
