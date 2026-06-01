package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// Doctor implements `code-audit doctor`. Diagnoses the bootstrap state of
// each on-disk extractor: source path, manifest validity, runtime tool
// availability (parsed from manifest.requires), and bootstrap_status from
// state.json. Surfaces actionable recommendations for any failed /
// missing piece. Exit 0 if everything is healthy, 1 if any issue is
// detected (so `doctor` is CI-friendly as a pre-extract gate).
func Doctor(args []string, stdout io.Writer) int {
	fset := flag.NewFlagSet("doctor", flag.ContinueOnError)
	extractorsDir := fset.String("extractors-dir", "", "explicit extractors directory")
	if err := fset.Parse(args); err != nil {
		return 2
	}

	var problems []string

	dest := defaultDest()
	fmt.Fprintf(stdout, "Audit home:        %s\n", dest)

	cwd, _ := os.Getwd()
	xpath, _, xlabel, xerr := discovery.ResolveExtractorsDir(discovery.ExtractorOpts{
		Flag:          *extractorsDir,
		AuditHome:     os.Getenv("AUDIT_HOME"),
		CWD:           cwd,
		HomeDir:       homeDirOrEmpty(),
		XDGConfigHome: os.Getenv("XDG_CONFIG_HOME"),
	})
	xpathExists := false
	if xerr == nil {
		if info, err := os.Stat(xpath); err == nil && info.IsDir() {
			xpathExists = true
		}
	}
	switch {
	case xerr != nil:
		fmt.Fprintf(stdout, "Extractors source: UNRESOLVED  (%v)\n", xerr)
		problems = append(problems, "No extractors source resolved — set --extractors-dir, or run `code-audit extract <name>` to auto-populate ~/.config/audit/.")
	case !xpathExists:
		fmt.Fprintf(stdout, "Extractors source: PENDING  %s  (will be created on first `code-audit extract`)\n", xpath)
		problems = append(problems, "Extractors source not yet on disk — run `code-audit extract <name>` to auto-populate.")
	default:
		fmt.Fprintf(stdout, "Extractors source: %s  (%s)\n", xlabel, xpath)
	}

	var state *InitState
	if dest != "" {
		state, _ = loadState(dest)
	}
	switch {
	case state == nil:
		fmt.Fprintf(stdout, "State:             (no state.json yet at %s)\n", filepath.Join(dest, stateFile))
	default:
		fmt.Fprintf(stdout, "State:             %s\n", filepath.Join(dest, stateFile))
		fmt.Fprintf(stdout, "                   audit-version=%s, applied=%s, source=%s\n",
			state.AuditVersion, state.AppliedAt, state.SourceRepoRoot)
	}

	if xpathExists {
		entries, err := os.ReadDir(xpath)
		if err != nil {
			fmt.Fprintf(stdout, "\nExtractors:        UNREADABLE  (%v)\n", err)
			problems = append(problems, fmt.Sprintf("Could not read extractors directory %s: %v", xpath, err))
		} else {
			names := make([]string, 0, len(entries))
			for _, e := range entries {
				if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
					names = append(names, e.Name())
				}
			}
			sort.Strings(names)
			if len(names) == 0 {
				fmt.Fprintln(stdout, "\nExtractors:        (none on disk yet)")
			} else {
				fmt.Fprintln(stdout, "\nExtractors:")
				toolProbed := map[string]bool{}
				for _, name := range names {
					renderExtractorDoctor(stdout, name, filepath.Join(xpath, name), state, toolProbed, &problems)
				}
			}
		}
	}

	if len(problems) > 0 {
		fmt.Fprintln(stdout, "\nRecommendations:")
		for _, p := range problems {
			fmt.Fprintf(stdout, "  - %s\n", p)
		}
		return 1
	}

	fmt.Fprintln(stdout, "\nNo issues detected.")
	return 0
}

// renderExtractorDoctor emits one extractor's section and appends any
// surfaced issues to *problems. toolProbed memoises exec.LookPath
// results across extractors so the same tool isn't probed twice.
func renderExtractorDoctor(stdout io.Writer, name, extractorDir string, state *InitState, toolProbed map[string]bool, problems *[]string) {
	fmt.Fprintf(stdout, "  %s\n", name)
	fmt.Fprintf(stdout, "    path:        %s\n", extractorDir)

	m, err := manifest.Parse(filepath.Join(extractorDir, "manifest.toml"))
	if err != nil {
		fmt.Fprintf(stdout, "    manifest:    INVALID — %v\n", err)
		*problems = append(*problems, fmt.Sprintf("Extractor %q has an invalid manifest. Fix the file or re-run `code-audit init --upgrade --force` to overwrite from the embedded copy.", name))
		return
	}
	fmt.Fprintf(stdout, "    manifest:    valid (schema %d)\n", m.SchemaVersion)

	for _, req := range m.Runtime.Requires {
		tool := requireToolName(req)
		if tool == "" {
			continue
		}
		if isPlatformMarker(tool) {
			// Platform-only constraints (e.g. "macOS >= 13") are not
			// PATH-tool probes; report them informationally and don't
			// raise a recommendation. Doctor doesn't yet verify
			// platform-version constraints.
			fmt.Fprintf(stdout, "    platform:    %s  (informational; not PATH-probed)\n", req)
			continue
		}
		onPath, seen := toolProbed[tool]
		if !seen {
			_, lookErr := exec.LookPath(tool)
			onPath = lookErr == nil
			toolProbed[tool] = onPath
		}
		label := "ok"
		if !onPath {
			label = "MISSING"
			*problems = append(*problems, fmt.Sprintf("Extractor %q requires %q on PATH (manifest declares: %q).", name, tool, req))
		}
		fmt.Fprintf(stdout, "    runtime:     %s  (requires %s)  %s\n", tool, req, label)
	}

	renderDoctorBootstrap(stdout, name, state, problems)
}

// renderDoctorBootstrap surfaces the per-extractor bootstrap_status from
// state.json. Mirrors status.go's renderer at the case-switch level but
// uses doctor's narrower layout and routes failures into the problems
// slice for the recommendations section.
func renderDoctorBootstrap(stdout io.Writer, name string, state *InitState, problems *[]string) {
	if state == nil {
		fmt.Fprintln(stdout, "    bootstrap:   pending (state.json absent; will run on next `code-audit extract`)")
		return
	}
	es, ok := state.Extractors[name]
	if !ok {
		fmt.Fprintln(stdout, "    bootstrap:   pending (no state.json entry; will run on next `code-audit extract`)")
		return
	}
	switch es.BootstrapStatus {
	case BootstrapOK:
		when := "?"
		if es.BootstrappedAt != nil {
			when = es.BootstrappedAt.UTC().Format(time.RFC3339)
		}
		fmt.Fprintf(stdout, "    bootstrap:   ok (%s)\n", when)
	case BootstrapFailed:
		firstLine := strings.SplitN(strings.TrimSpace(es.LastError), "\n", 2)[0]
		if firstLine == "" {
			firstLine = "(no error captured)"
		}
		fmt.Fprintf(stdout, "    bootstrap:   FAILED — %s\n", firstLine)
		*problems = append(*problems, fmt.Sprintf("Extractor %q bootstrap failed. Re-run `code-audit extract %s` to retry; if the failure persists, check the manifest's [runtime].setup_hint.", name, name))
	case BootstrapNA:
		fmt.Fprintln(stdout, "    bootstrap:   n/a (no [runtime].bootstrap declared)")
	case BootstrapPending, "":
		fmt.Fprintln(stdout, "    bootstrap:   pending (will run on next `code-audit extract`)")
	default:
		fmt.Fprintf(stdout, "    bootstrap:   %s (unknown status)\n", es.BootstrapStatus)
		*problems = append(*problems, fmt.Sprintf("Extractor %q has an unrecognised bootstrap_status %q in state.json — manually edit the file or re-run init.", name, es.BootstrapStatus))
	}
}

// platformMarkers lists tokens that may appear in manifest.requires but
// designate a platform / OS rather than a binary on PATH. exec.LookPath
// would deterministically miss these, so doctor reports them as
// informational without raising a recommendation. Matching is
// case-insensitive on the canonical names. The list is intentionally
// small — adding new markers should be a deliberate decision pinned by
// a test.
var platformMarkers = map[string]bool{
	"macos":   true,
	"linux":   true,
	"darwin":  true,
	"windows": true,
	"unix":    true,
	"posix":   true,
}

// isPlatformMarker reports whether tool names a platform constraint
// rather than a PATH binary.
func isPlatformMarker(tool string) bool {
	return platformMarkers[strings.ToLower(tool)]
}

// requireToolName extracts the executable name from a free-form
// `manifest.requires` entry like "node >= 18" or "swift". The convention
// is that the first whitespace-delimited token is the tool name; anything
// after is an informational version constraint. Returns "" when the
// requires entry is blank.
func requireToolName(req string) string {
	req = strings.TrimSpace(req)
	if req == "" {
		return ""
	}
	if idx := strings.IndexAny(req, " \t"); idx != -1 {
		return req[:idx]
	}
	return req
}
