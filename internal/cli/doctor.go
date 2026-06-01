package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// Doctor implements `code-audit doctor`. Diagnoses the bootstrap state of
// each extractor: source path, manifest validity, runtime tool
// availability (parsed from manifest.requires), and bootstrap_status from
// state.json. Surfaces actionable recommendations for any failed /
// missing piece. Exit 0 if everything is healthy, 1 if any issue is
// detected (so `doctor` is CI-friendly as a pre-extract gate); 2 on
// flag-parse errors.
func Doctor(args []string, stdout io.Writer) int {
	fset := flag.NewFlagSet("doctor", flag.ContinueOnError)
	// Route flag-parse errors and help text into stdout so callers using
	// an injected writer (tests, library embeds) actually capture them.
	fset.SetOutput(stdout)
	extractorsDir := fset.String("extractors-dir", "", "explicit extractors directory")
	if err := fset.Parse(args); err != nil {
		// `-h` / `--help` returns flag.ErrHelp; the user explicitly asked
		// for help and conventionally that's a 0 exit.
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if fset.NArg() > 0 {
		fmt.Fprintf(stdout, "code-audit doctor: unexpected positional argument %q (doctor takes no positional args)\n", fset.Arg(0))
		return 2
	}

	var problems []string

	// Resolve the extractors directory first so we can derive the audit
	// home from it when the user is overriding via $AUDIT_HOME or
	// --extractors-dir. defaultDest() honors $XDG_CONFIG_HOME / $HOME
	// for the tier-4 case but DOES NOT honor $AUDIT_HOME — without
	// deriving from xpath, state.json reads from a different audit home
	// than the extractors source.
	cwd, _ := os.Getwd()
	xpath, tier, xlabel, xerr := discovery.ResolveExtractorsDir(discovery.ExtractorOpts{
		Flag:          *extractorsDir,
		AuditHome:     os.Getenv("AUDIT_HOME"),
		CWD:           cwd,
		HomeDir:       homeDirOrEmpty(),
		XDGConfigHome: os.Getenv("XDG_CONFIG_HOME"),
	})
	xpathExists, xpathIsFile := false, false
	if xerr == nil {
		if info, err := os.Stat(xpath); err == nil {
			if info.IsDir() {
				xpathExists = true
			} else {
				xpathIsFile = true
			}
		}
	}

	// Audit home: prefer the one that owns the resolved extractors dir,
	// so state.json and the extractor source stay co-located.
	dest := auditHomeForTier(xpath, tier)
	if dest == "" {
		fmt.Fprintln(stdout, "Audit home:        UNRESOLVED (set $HOME or $XDG_CONFIG_HOME)")
		problems = append(problems, "Cannot resolve an audit home — $HOME and $XDG_CONFIG_HOME are both unset. Set one of them, or run `code-audit init --dest <path>` against an explicit destination.")
	} else {
		fmt.Fprintf(stdout, "Audit home:        %s\n", dest)
	}

	switch {
	case xerr != nil:
		fmt.Fprintf(stdout, "Extractors source: UNRESOLVED  (%v)\n", xerr)
		problems = append(problems, "No extractors source resolved — set --extractors-dir, or run `code-audit extract <name>` to auto-populate ~/.config/audit/.")
	case xpathIsFile:
		fmt.Fprintf(stdout, "Extractors source: NOT A DIRECTORY  %s\n", xpath)
		problems = append(problems, fmt.Sprintf("Path %s exists but is a regular file, not a directory. Remove or rename it so `code-audit extract` can populate the tree.", xpath))
	case !xpathExists:
		fmt.Fprintf(stdout, "Extractors source: PENDING  %s  (will be created on first `code-audit extract`)\n", xpath)
		problems = append(problems, "Extractors source not yet on disk — run `code-audit extract <name>` to auto-populate.")
	default:
		fmt.Fprintf(stdout, "Extractors source: %s  (%s)\n", xlabel, xpath)
	}

	// State.json — surface parse errors loudly (an unreadable state is
	// exactly the kind of diagnosis doctor exists to produce, not silently
	// reclassify as 'absent').
	var state *InitState
	statePath := ""
	if dest != "" {
		statePath = filepath.Join(dest, stateFile)
		s, err := loadState(dest)
		switch {
		case err != nil:
			fmt.Fprintf(stdout, "State:             UNREADABLE  %s  (%v)\n", statePath, err)
			problems = append(problems, fmt.Sprintf("state.json at %s is present but unreadable: %v. Back it up and run `code-audit init --upgrade --force` to regenerate.", statePath, err))
		case s == nil:
			fmt.Fprintf(stdout, "State:             (no state.json yet at %s)\n", statePath)
		default:
			state = s
			fmt.Fprintf(stdout, "State:             %s\n", statePath)
			fmt.Fprintf(stdout, "                   audit-version=%s, applied=%s, source=%s\n",
				state.AuditVersion, state.AppliedAt, state.SourceRepoRoot)
		}
	}

	// Iterate the union of (extractors found on disk) ∪ (extractors in
	// state.Extractors). State entries that point at deleted directories
	// surface as drift here instead of being silently dropped.
	diskExtractors := map[string]string{} // name → on-disk path
	if xpathExists {
		entries, err := os.ReadDir(xpath)
		if err != nil {
			fmt.Fprintf(stdout, "\nExtractors:        UNREADABLE  (%v)\n", err)
			problems = append(problems, fmt.Sprintf("Could not read extractors directory %s: %v", xpath, err))
		} else {
			for _, e := range entries {
				name := e.Name()
				if strings.HasPrefix(name, ".") {
					continue
				}
				// IsDir() returns false for symlinks even when the target is
				// a directory; explicitly Stat through the link so a
				// contributor's `extractors/typescript -> /repo/.../typescript`
				// symlink isn't silently skipped.
				full := filepath.Join(xpath, name)
				info, statErr := os.Stat(full)
				if statErr != nil || !info.IsDir() {
					continue
				}
				diskExtractors[name] = full
			}
		}
	}

	allNames := map[string]bool{}
	for n := range diskExtractors {
		allNames[n] = true
	}
	if state != nil {
		for n := range state.Extractors {
			allNames[n] = true
		}
	}
	names := make([]string, 0, len(allNames))
	for n := range allNames {
		names = append(names, n)
	}
	sort.Strings(names)

	if xpathExists && len(diskExtractors) == 0 && len(names) == 0 {
		fmt.Fprintln(stdout, "\nExtractors:        (none on disk yet)")
		problems = append(problems, "Extractors directory exists but is empty — run `code-audit extract <name>` to populate, or pass --extractors-dir to a populated checkout.")
	} else if len(names) > 0 {
		fmt.Fprintln(stdout, "\nExtractors:")
		toolProbed := map[string]bool{}
		for _, name := range names {
			if onDiskPath, ok := diskExtractors[name]; ok {
				renderExtractorDoctor(stdout, name, onDiskPath, state, toolProbed, &problems)
			} else {
				// State refers to an extractor whose directory is gone.
				renderOrphanedExtractor(stdout, name, filepath.Join(xpath, name), state, &problems)
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

// auditHomeForTier returns the audit-home path that owns the resolved
// extractors directory. For TierConfigDir (defaultDest's path) the
// result matches defaultDest(). For TierFlag, TierCwd, TierAuditHome the
// answer is filepath.Dir(xpath) so state.json reads land in the same
// home that owns the extractors. Returns "" when nothing resolved or
// HOME / XDG_CONFIG_HOME are unset.
func auditHomeForTier(xpath string, tier discovery.Tier) string {
	switch tier {
	case discovery.TierFlag, discovery.TierCwd, discovery.TierAuditHome:
		if xpath == "" {
			return ""
		}
		return filepath.Dir(xpath)
	default:
		return defaultDest()
	}
}

// renderExtractorDoctor emits one extractor's section and appends any
// surfaced issues to *problems. toolProbed memoises exec.LookPath
// results across extractors (case-insensitive) so the same tool isn't
// probed twice.
func renderExtractorDoctor(stdout io.Writer, name, extractorDir string, state *InitState, toolProbed map[string]bool, problems *[]string) {
	fmt.Fprintf(stdout, "  %s\n", name)
	fmt.Fprintf(stdout, "    path:        %s\n", extractorDir)

	m, err := manifest.Parse(filepath.Join(extractorDir, "manifest.toml"))
	if err != nil {
		fmt.Fprintf(stdout, "    manifest:    INVALID — %v\n", err)
		*problems = append(*problems, fmt.Sprintf("Extractor %q has an invalid manifest. Either fix the file directly, or delete the extractor directory (%s) and re-run `code-audit extract %s` to repopulate it from the embedded source.", name, extractorDir, name))
		// Still surface bootstrap state — diagnosis should not stop at
		// the first problem.
		renderDoctorBootstrap(stdout, name, state, problems)
		return
	}
	fmt.Fprintf(stdout, "    manifest:    valid (schema %d)\n", m.SchemaVersion)

	for _, req := range m.Runtime.Requires {
		tool := requireToolName(req)
		if tool == "" {
			continue
		}
		// A "requires" entry that's all operator / version with no tool
		// name (e.g. ">=18" or "^1.2.3") is a manifest authoring bug,
		// not a PATH lookup — surface it as such rather than probing
		// the operator string.
		if !looksLikeToolName(tool) {
			fmt.Fprintf(stdout, "    runtime:     MALFORMED  (requires %q has no tool name)\n", req)
			*problems = append(*problems, fmt.Sprintf("Extractor %q has a malformed `requires` entry %q — expected '<tool> [version constraint]'.", name, req))
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
		cacheKey := strings.ToLower(tool)
		onPath, seen := toolProbed[cacheKey]
		if !seen {
			_, lookErr := exec.LookPath(tool)
			onPath = lookErr == nil
			toolProbed[cacheKey] = onPath
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

// renderOrphanedExtractor handles the state-vs-disk drift case: a
// state.Extractors entry references an extractor whose directory is no
// longer present. Surfaces the entry and recommends either re-running
// extract (to repopulate) or pruning state.json (to forget).
func renderOrphanedExtractor(stdout io.Writer, name, expectedPath string, state *InitState, problems *[]string) {
	fmt.Fprintf(stdout, "  %s\n", name)
	fmt.Fprintf(stdout, "    path:        %s  (MISSING)\n", expectedPath)
	*problems = append(*problems, fmt.Sprintf("Extractor %q has a state.json entry but no on-disk directory at %s. Run `code-audit extract %s` to repopulate, or remove the entry from state.json to forget it.", name, expectedPath, name))
	renderDoctorBootstrap(stdout, name, state, problems)
}

// renderDoctorBootstrap surfaces the per-extractor bootstrap_status from
// state.json. Casing and separators match status.go's renderer
// (lowercase status labels, " — " separator before captured errors) so
// users grepping logs / docs see the same wording from both subcommands.
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
		firstLine := firstLineOf(es.LastError)
		if firstLine == "" {
			firstLine = "(no error captured)"
		}
		fmt.Fprintf(stdout, "    bootstrap:   failed: %s\n", firstLine)
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

// firstLineOf returns the first line of s with trailing CR / LF
// stripped. Captured stderr from CRLF-emitting tools would otherwise
// leak a \r into terminal output, overprinting the next character.
func firstLineOf(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i != -1 {
		s = s[:i]
	}
	return strings.TrimRight(s, "\r")
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
	"ios":     true,
	"android": true,
	"freebsd": true,
	"netbsd":  true,
	"openbsd": true,
}

// isPlatformMarker reports whether tool names a platform constraint
// rather than a PATH binary.
func isPlatformMarker(tool string) bool {
	return platformMarkers[strings.ToLower(tool)]
}

// looksLikeToolName reports whether tool is plausibly a binary name —
// must start with a letter or underscore. Pure-operator entries like
// ">=18" or "^1.2.3" fail this check and are surfaced as malformed
// `requires` rather than a misleading "binary not on PATH".
func looksLikeToolName(tool string) bool {
	if tool == "" {
		return false
	}
	r := rune(tool[0])
	return unicode.IsLetter(r) || r == '_' || r == '.' || r == '/'
}

// requireToolName extracts the executable name from a free-form
// `manifest.requires` entry like "node >= 18" or "swift". The convention
// is that the first whitespace-delimited token is the tool name; anything
// after is an informational version constraint. Splits on any Unicode
// whitespace AND on a leading version operator (>=, <=, <, >, ==) so
// `node>=18` (no spaces) and `node\r>= 18` (CRLF-edited manifest) both
// resolve to "node". Returns "" when the requires entry is blank.
func requireToolName(req string) string {
	req = strings.TrimSpace(req)
	if req == "" {
		return ""
	}
	// Break on any Unicode whitespace.
	if i := strings.IndexFunc(req, unicode.IsSpace); i != -1 {
		req = req[:i]
	}
	// Break on a leading version operator (>=, <=, <, >, ==, =) ONLY
	// when there's a tool-name prefix; if the operator is at position 0
	// (e.g. `">=18"`), keep the full string so looksLikeToolName can
	// catch the malformed entry downstream.
	if i := strings.IndexAny(req, "<>="); i > 0 {
		req = req[:i]
	}
	return req
}
