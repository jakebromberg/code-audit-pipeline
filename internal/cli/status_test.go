package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// Test 20 — renderExtractorBootstrapState snapshot across the four
// BootstrapStatus values (ok | failed | pending | n-a).
func TestRenderExtractorBootstrapState_AllStatuses(t *testing.T) {
	alphaAt := time.Date(2026, 6, 1, 12, 34, 56, 0, time.UTC)
	state := &InitState{
		AuditVersion:   "test",
		SourceRepoRoot: "<embedded>",
		Files:          map[string]InitStateFile{},
		Extractors: map[string]ExtractorState{
			"alpha":   {BootstrapStatus: BootstrapOK, BootstrappedAt: &alphaAt},
			"bravo":   {BootstrapStatus: BootstrapFailed, LastError: "npm install: ENOENT\nstack trace ignored\n"},
			"charlie": {BootstrapStatus: BootstrapPending},
			"delta":   {BootstrapStatus: BootstrapNA},
		},
	}

	var buf bytes.Buffer
	renderExtractorBootstrapState(&buf, state, "/home/jake/.config/audit", "/home/jake")
	got := buf.String()

	wantContains := []string{
		"Extractors:",
		"alpha: ~/.config/audit/extractors/alpha  [<embedded>]",
		"bootstrap: ok (2026-06-01T12:34:56Z)",
		"bravo: ~/.config/audit/extractors/bravo  [<embedded>]",
		"bootstrap: failed: npm install: ENOENT",
		"charlie: ~/.config/audit/extractors/charlie  [<embedded>]",
		"bootstrap: pending (will run on next `extract`)",
		"delta: ~/.config/audit/extractors/delta  [<embedded>]",
		"bootstrap: n/a (no [runtime].bootstrap declared)",
	}
	for _, want := range wantContains {
		if !strings.Contains(got, want) {
			t.Errorf("status output missing %q\n--- got ---\n%s", want, got)
		}
	}
}

// Edge case — failed status without LastError populated still renders a
// sensible message instead of "failed: ".
func TestRenderExtractorBootstrapState_FailedNoLastError(t *testing.T) {
	state := &InitState{
		Extractors: map[string]ExtractorState{
			"x": {BootstrapStatus: BootstrapFailed},
		},
	}
	var buf bytes.Buffer
	renderExtractorBootstrapState(&buf, state, "/home/jake/.config/audit", "/home/jake")
	if !strings.Contains(buf.String(), "(no error captured)") {
		t.Errorf("missing fallback for empty LastError: %s", buf.String())
	}
}

// Suppression — nil state or empty Extractors prints nothing.
func TestRenderExtractorBootstrapState_NilSuppressed(t *testing.T) {
	var buf bytes.Buffer
	renderExtractorBootstrapState(&buf, nil, "/x", "/home/jake")
	if buf.Len() != 0 {
		t.Errorf("nil state should print nothing, got %q", buf.String())
	}
	buf.Reset()
	renderExtractorBootstrapState(&buf, &InitState{}, "/x", "/home/jake")
	if buf.Len() != 0 {
		t.Errorf("empty Extractors should print nothing, got %q", buf.String())
	}
}
