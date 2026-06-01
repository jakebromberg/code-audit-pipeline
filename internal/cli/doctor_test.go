package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// setupDoctorHome builds a fake audit home under tmp with the requested
// extractor layout. extractorsFiles maps `<name>/<rel-path>` → file body;
// `<name>/manifest.toml` content controls manifest validity. Returns the
// audit-home path; HOME is also set via t.Setenv so defaultDest() and
// discovery both resolve into this tree.
func setupDoctorHome(t *testing.T, extractorsFiles map[string]string, stateExtractors map[string]ExtractorState) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AUDIT_HOME", "")

	auditDest := filepath.Join(home, ".config", "audit")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}

	for rel, body := range extractorsFiles {
		full := filepath.Join(extractorsRoot, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if stateExtractors != nil {
		state := &InitState{
			AuditVersion:   "test",
			SourceRepoRoot: "<embedded>",
			AppliedAt:      time.Now().UTC().Format(time.RFC3339),
			Files:          map[string]InitStateFile{},
			Extractors:     stateExtractors,
		}
		if err := os.MkdirAll(filepath.Join(auditDest, ".audit-init"), 0o755); err != nil {
			t.Fatal(err)
		}
		data, _ := json.MarshalIndent(state, "", "  ")
		if err := os.WriteFile(filepath.Join(auditDest, ".audit-init", "state.json"), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return auditDest
}

// validManifest returns a schema-2 manifest body declaring the given
// `requires` and `bootstrap` for use in doctor tests.
func validManifest(name string, requires []string, bootstrap []string) string {
	body := `schema_version = 2
[extractor]
name = "` + name + `"
version = "0.0.1"
[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["node", "type-catalog.mjs", "--output", "{output}"]

[runtime]
`
	if len(requires) > 0 {
		body += `requires = [`
		for i, r := range requires {
			if i > 0 {
				body += ", "
			}
			body += `"` + r + `"`
		}
		body += `]
`
	}
	if len(bootstrap) > 0 {
		body += `bootstrap = [`
		for i, b := range bootstrap {
			if i > 0 {
				body += ", "
			}
			body += `"` + b + `"`
		}
		body += `]
`
	}
	return body
}

// Test 1 — healthy install: an extractor with a valid manifest and an
// `ok` bootstrap entry reports no issues and exits 0.
func TestDoctor_HealthyInstallReportsNoIssues(t *testing.T) {
	now := time.Now().UTC()
	setupDoctorHome(t,
		map[string]string{
			// `sh` is guaranteed on PATH for darwin/linux test runners;
			// using it for the runtime probe avoids depending on `node`
			// being installed in CI.
			"typescript/manifest.toml": validManifest("typescript", []string{"sh"}, []string{"sh", "-c", "true"}),
		},
		map[string]ExtractorState{
			"typescript": {BootstrapStatus: BootstrapOK, BootstrappedAt: &now},
		},
	)

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 0 {
		t.Fatalf("Doctor exit=%d (want 0), out=%s", exit, out.String())
	}
	got := out.String()
	for _, want := range []string{
		"Extractors:",
		"typescript",
		"manifest:    valid (schema 2)",
		"runtime:     sh  (requires sh)  ok",
		"bootstrap:   ok",
		"No issues detected.",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in output:\n%s", want, got)
		}
	}
}

// Test 2 — extractors directory absent (tier-4 not yet auto-populated).
// Doctor surfaces PENDING + a recommendation; exit 1 so CI scripts can
// gate on it.
func TestDoctor_TierConfigDirMissingReportsPending(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AUDIT_HOME", "")

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "PENDING") {
		t.Errorf("missing PENDING marker: %s", got)
	}
	if !strings.Contains(got, "Recommendations:") {
		t.Errorf("missing Recommendations section: %s", got)
	}
}

// Test 3 — invalid manifest surfaces an INVALID line and a recommendation.
func TestDoctor_InvalidManifestSurfacesError(t *testing.T) {
	setupDoctorHome(t,
		map[string]string{
			"borked/manifest.toml": "schema_version = 99\n",
		},
		nil,
	)

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "manifest:    INVALID") {
		t.Errorf("missing INVALID marker: %s", got)
	}
	if !strings.Contains(got, "invalid manifest") {
		t.Errorf("missing recommendation about invalid manifest: %s", got)
	}
}

// Test 4 — runtime tool not on PATH is flagged. Uses a deliberately
// unlikely-to-exist binary name so the probe deterministically misses.
func TestDoctor_MissingRuntimeToolReported(t *testing.T) {
	setupDoctorHome(t,
		map[string]string{
			"typescript/manifest.toml": validManifest("typescript", []string{"definitely-not-a-real-binary-fb37"}, nil),
		},
		nil,
	)

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "MISSING") {
		t.Errorf("missing MISSING marker: %s", got)
	}
	if !strings.Contains(got, "requires \"definitely-not-a-real-binary-fb37\" on PATH") {
		t.Errorf("missing recommendation citing the tool name: %s", got)
	}
}

// Test 5 — failed bootstrap surfaces the LastError first-line and a
// recommendation to retry.
func TestDoctor_FailedBootstrapSurfacesLastError(t *testing.T) {
	now := time.Now().UTC()
	setupDoctorHome(t,
		map[string]string{
			"typescript/manifest.toml": validManifest("typescript", []string{"sh"}, []string{"sh", "-c", "false"}),
		},
		map[string]ExtractorState{
			"typescript": {
				BootstrapStatus: BootstrapFailed,
				BootstrappedAt:  &now,
				LastError:       "npm install: ENOENT\nstack trace ignored",
			},
		},
	)

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "failed: npm install: ENOENT") {
		t.Errorf("missing failure detail: %s", got)
	}
	if !strings.Contains(got, "Re-run `code-audit extract typescript`") {
		t.Errorf("missing retry recommendation: %s", got)
	}
}

// Test 6 — extractor on disk but no state.json entry yet reports pending
// (covers the just-init'd-not-yet-extracted window).
func TestDoctor_NoStateEntryReportsPending(t *testing.T) {
	setupDoctorHome(t,
		map[string]string{
			"typescript/manifest.toml": validManifest("typescript", []string{"sh"}, nil),
		},
		nil, // state.json not written
	)

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	// No bootstrap failure → exit 0 (manifest valid + runtime ok).
	if exit != 0 {
		t.Fatalf("Doctor exit=%d (want 0), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "bootstrap:   pending") {
		t.Errorf("missing pending marker: %s", got)
	}
}

// Test 7 — platform markers in `requires` (e.g. "macOS >= 13") are
// reported informationally without raising a MISSING recommendation.
// exec.LookPath would deterministically miss these.
func TestDoctor_PlatformMarkerNotProbed(t *testing.T) {
	setupDoctorHome(t,
		map[string]string{
			"swift/manifest.toml": validManifest("swift", []string{"sh", "macOS >= 13"}, nil),
		},
		nil,
	)

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 0 {
		t.Fatalf("Doctor exit=%d (want 0 — no real MISSING), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "platform:    macOS >= 13  (informational; not PATH-probed)") {
		t.Errorf("missing platform-marker rendering: %s", got)
	}
	if strings.Contains(got, "requires \"macOS\" on PATH") {
		t.Errorf("platform marker leaked into recommendations: %s", got)
	}
}

// Test 8 — unreadable state.json (parse error) is surfaced via UNREADABLE
// marker and an actionable recommendation. Pre-fix, the parse error was
// swallowed and the state was reported as 'no state.json yet'.
func TestDoctor_UnreadableStateJSONSurfacesError(t *testing.T) {
	auditDest := setupDoctorHome(t,
		map[string]string{
			"typescript/manifest.toml": validManifest("typescript", []string{"sh"}, nil),
		},
		nil,
	)
	// Write a truncated state.json to trigger a JSON parse error.
	if err := os.MkdirAll(filepath.Join(auditDest, ".audit-init"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(auditDest, ".audit-init", "state.json"), []byte("{ truncated and broken"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1 for unreadable state), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "State:             UNREADABLE") {
		t.Errorf("missing UNREADABLE marker: %s", got)
	}
	if !strings.Contains(got, "unreadable") {
		t.Errorf("missing recommendation about unreadable state: %s", got)
	}
}

// Test 9 — orphaned state.Extractors entry (extractor in state.json but
// no on-disk directory) is surfaced. Pre-fix, the `if xpathExists` gate
// silently dropped these entries.
func TestDoctor_OrphanedStateEntrySurfaced(t *testing.T) {
	now := time.Now().UTC()
	setupDoctorHome(t,
		map[string]string{
			// Only swift on disk; typescript exists only in state.
			"swift/manifest.toml": validManifest("swift", []string{"sh"}, nil),
		},
		map[string]ExtractorState{
			"typescript": {BootstrapStatus: BootstrapOK, BootstrappedAt: &now},
		},
	)

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "typescript") {
		t.Errorf("orphaned extractor name not rendered: %s", got)
	}
	if !strings.Contains(got, "(MISSING)") {
		t.Errorf("missing MISSING marker on orphaned path: %s", got)
	}
	if !strings.Contains(got, "no on-disk directory") {
		t.Errorf("missing recommendation about orphaned state entry: %s", got)
	}
}

// Test 10 — regular file at xpath is reported as 'NOT A DIRECTORY' with
// a recommendation. Pre-fix, doctor printed PENDING (will be created).
func TestDoctor_RegularFileAtXpathIsDistinguished(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AUDIT_HOME", "")

	// Place a regular file where the extractors directory should be.
	auditDest := filepath.Join(home, ".config", "audit")
	if err := os.MkdirAll(auditDest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(auditDest, "extractors"), []byte("oops"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "NOT A DIRECTORY") {
		t.Errorf("missing 'NOT A DIRECTORY' marker: %s", got)
	}
	if !strings.Contains(got, "Remove or rename it") {
		t.Errorf("missing actionable recommendation: %s", got)
	}
}

// Test 11 — symlinked extractor entry is visible. Pre-fix, DirEntry.IsDir
// returned false for symlinks and the extractor was silently skipped.
func TestDoctor_SymlinkedExtractorVisible(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AUDIT_HOME", "")

	// Build a real extractor directory outside the audit home, then
	// symlink it under extractors/.
	realDir := filepath.Join(t.TempDir(), "real-typescript")
	if err := os.MkdirAll(realDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(realDir, "manifest.toml"), []byte(validManifest("typescript", []string{"sh"}, nil)), 0o644); err != nil {
		t.Fatal(err)
	}
	extractorsRoot := filepath.Join(home, ".config", "audit", "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realDir, filepath.Join(extractorsRoot, "typescript")); err != nil {
		t.Skipf("symlink unsupported: %v", err)
	}

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 0 {
		t.Fatalf("Doctor exit=%d (want 0), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "typescript") {
		t.Errorf("symlinked extractor not rendered: %s", got)
	}
	if !strings.Contains(got, "manifest:    valid (schema 2)") {
		t.Errorf("manifest reachable through symlink not parsed: %s", got)
	}
}

// Test 12 — empty extractors directory raises a recommendation instead
// of green-lighting a known-broken state.
func TestDoctor_EmptyExtractorsDirRaisesRecommendation(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AUDIT_HOME", "")
	if err := os.MkdirAll(filepath.Join(home, ".config", "audit", "extractors"), 0o755); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1 for empty dir), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "(none on disk yet)") {
		t.Errorf("missing empty-dir marker: %s", got)
	}
	if !strings.Contains(got, "is empty") {
		t.Errorf("missing recommendation citing the empty dir: %s", got)
	}
}

// Test 13 — `-h` returns 0 (help is not an error). Pre-fix, flag.ErrHelp
// fell through to the catch-all `return 2`, which made `code-audit
// doctor -h` look like a CLI error.
func TestDoctor_HelpFlagExitsZero(t *testing.T) {
	var out bytes.Buffer
	exit := Doctor([]string{"-h"}, &out)
	if exit != 0 {
		t.Fatalf("Doctor -h exit=%d (want 0), out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "extractors-dir") {
		t.Errorf("expected usage text to mention --extractors-dir: %s", out.String())
	}
}

// Test 14 — flag-parse errors go to the injected writer, not os.Stderr.
// Lets tests (and library embedders) capture diagnostic output.
func TestDoctor_FlagErrorsRouteToInjectedWriter(t *testing.T) {
	var out bytes.Buffer
	exit := Doctor([]string{"--this-is-not-a-real-flag"}, &out)
	if exit != 2 {
		t.Fatalf("Doctor exit=%d (want 2 for unknown flag), out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "this-is-not-a-real-flag") {
		t.Errorf("flag-error text missing from injected writer: %s", out.String())
	}
}

// Test 15 — positional arguments produce a clear error instead of being
// silently consumed.
func TestDoctor_PositionalArgsRejected(t *testing.T) {
	var out bytes.Buffer
	exit := Doctor([]string{"typescript"}, &out)
	if exit != 2 {
		t.Fatalf("Doctor with positional exit=%d (want 2), out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "unexpected positional argument") {
		t.Errorf("missing positional-arg error: %s", out.String())
	}
}

// Test 16 — `firstLineOf` strips trailing \r from CRLF-captured stderr
// so it doesn't leak a carriage return into terminal output.
func TestFirstLineOf(t *testing.T) {
	cases := []struct{ in, want string }{
		{"npm install: ENOENT\r\nstack trace", "npm install: ENOENT"},
		{"npm install: ENOENT\nstack trace", "npm install: ENOENT"},
		{"npm install: ENOENT\r", "npm install: ENOENT"},
		{"", ""},
		{"   \n   ", ""},
		{"one-line", "one-line"},
	}
	for _, c := range cases {
		if got := firstLineOf(c.in); got != c.want {
			t.Errorf("firstLineOf(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// Test 17 — malformed `requires` entry (operator only, no tool name) is
// flagged as MALFORMED with a clear recommendation. Pre-fix, doctor
// would PATH-probe the operator string and report a confusing MISSING.
func TestDoctor_MalformedRequiresEntrySurfaced(t *testing.T) {
	setupDoctorHome(t,
		map[string]string{
			"typescript/manifest.toml": validManifest("typescript", []string{">=18"}, nil),
		},
		nil,
	)
	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 1 {
		t.Fatalf("Doctor exit=%d (want 1), out=%s", exit, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "MALFORMED") {
		t.Errorf("missing MALFORMED marker: %s", got)
	}
	if !strings.Contains(got, "expected '<tool> [version constraint]'") {
		t.Errorf("missing format-explanation recommendation: %s", got)
	}
}

// Test 18 — AUDIT_HOME-resolved extractors use the AUDIT_HOME audit home
// for state.json, not defaultDest() (~/.config/audit). Pre-fix the two
// halves of the report read from different homes.
func TestDoctor_AuditHomeStateLocationConsistent(t *testing.T) {
	home := t.TempDir()
	auditHome := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AUDIT_HOME", auditHome)

	// Populate AUDIT_HOME/extractors and AUDIT_HOME/.audit-init/state.json
	if err := os.MkdirAll(filepath.Join(auditHome, "extractors", "typescript"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(auditHome, "extractors", "typescript", "manifest.toml"),
		[]byte(validManifest("typescript", []string{"sh"}, nil)), 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	stateBlob := &InitState{
		AuditVersion:   "test",
		SourceRepoRoot: "<embedded>",
		AppliedAt:      now.Format(time.RFC3339),
		Files:          map[string]InitStateFile{},
		Extractors: map[string]ExtractorState{
			"typescript": {BootstrapStatus: BootstrapOK, BootstrappedAt: &now},
		},
	}
	if err := os.MkdirAll(filepath.Join(auditHome, ".audit-init"), 0o755); err != nil {
		t.Fatal(err)
	}
	data, _ := json.MarshalIndent(stateBlob, "", "  ")
	if err := os.WriteFile(filepath.Join(auditHome, ".audit-init", "state.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 0 {
		t.Fatalf("Doctor exit=%d (want 0 — AUDIT_HOME state should be readable), out=%s", exit, out.String())
	}
	got := out.String()
	// Audit home should be AUDIT_HOME, not ~/.config/audit.
	if !strings.Contains(got, "Audit home:        "+auditHome) {
		t.Errorf("audit home should match AUDIT_HOME (%s), got: %s", auditHome, got)
	}
	// State path should be under AUDIT_HOME.
	if !strings.Contains(got, filepath.Join(auditHome, ".audit-init", "state.json")) {
		t.Errorf("state.json path should be under AUDIT_HOME: %s", got)
	}
	// Bootstrap status from that state.json should be reflected.
	if !strings.Contains(got, "bootstrap:   ok") {
		t.Errorf("bootstrap status from AUDIT_HOME state.json not reflected: %s", got)
	}
}

// Test 19 — toolProbed dedup is case-insensitive so two manifests
// declaring "Node" and "node" both probe via a single LookPath call.
// Hard to verify the count without monkeypatching, but we can at least
// confirm both extractors render OK against the lowercase key.
func TestDoctor_ToolProbedCaseInsensitive(t *testing.T) {
	setupDoctorHome(t,
		map[string]string{
			"extra/manifest.toml":      validManifest("extra", []string{"Sh"}, nil),
			"typescript/manifest.toml": validManifest("typescript", []string{"sh"}, nil),
		},
		nil,
	)
	var out bytes.Buffer
	exit := Doctor(nil, &out)
	if exit != 0 {
		t.Fatalf("Doctor exit=%d (want 0), out=%s", exit, out.String())
	}
	got := out.String()
	// Both should resolve via PATH-found sh and render `ok`.
	for _, want := range []string{"Sh  (requires Sh)  ok", "sh  (requires sh)  ok"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in output:\n%s", want, got)
		}
	}
}

// Test 20 — requireToolName splits on broader whitespace AND on
// version-operator characters so `node>=18`, `node\t>= 18`, and
// `node\r>=18` all resolve to "node".
func TestRequireToolName(t *testing.T) {
	cases := []struct{ in, want string }{
		{"node >= 18", "node"},
		{"swift", "swift"},
		{"  python3 >= 3.11  ", "python3"},
		{"", ""},
		{"   ", ""},
		{"go\t>=1.24", "go"},
	}
	for _, c := range cases {
		if got := requireToolName(c.in); got != c.want {
			t.Errorf("requireToolName(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
