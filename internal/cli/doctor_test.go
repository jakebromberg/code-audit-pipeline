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
	if !strings.Contains(got, "FAILED — npm install: ENOENT") {
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

// Test 8 — requireToolName parses the leading non-whitespace token from
// the manifest.requires string and returns "" for blank input.
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
