package cli

import (
	"bytes"
	"context"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

// ensureExtractorSpy records EnsureExtractor invocations and returns a
// canned result. Installed via the ensureExtractor package-level seam in
// tests of the tier-gating logic (19, 19a, 19b).
type ensureExtractorSpy struct {
	calls int
	names []string
	ret   error
}

func (s *ensureExtractorSpy) Call(
	_ context.Context,
	name string,
	_ string,
	_ string,
	_ fs.FS,
	_ io.Writer,
) error {
	s.calls++
	s.names = append(s.names, name)
	return s.ret
}

func installEnsureSpy(t *testing.T, ret error) *ensureExtractorSpy {
	t.Helper()
	spy := &ensureExtractorSpy{ret: ret}
	prev := ensureExtractor
	ensureExtractor = spy.Call
	t.Cleanup(func() { ensureExtractor = prev })
	return spy
}

// minimalExtractorDir writes a manifest under <parent>/extractors/<name>/
// sufficient for manifest.Parse to succeed. Returns the extractor dir.
func minimalExtractorDir(t *testing.T, parent, name string) string {
	t.Helper()
	dir := filepath.Join(parent, "extractors", name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version = 1
[extractor]
name = "` + name + `"
version = "0.0.1"
[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["sh", "-c", "echo {output}"]
`
	if err := os.WriteFile(filepath.Join(dir, "manifest.toml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// fakeHome makes os.UserHomeDir() resolve into tmp by overriding $HOME.
// Returns the home path.
func fakeHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	return home
}

// Test 19 — cwd-local extractors/ present with the requested extractor:
// tier 2 wins. EnsureExtractor is not called even though ~/.config/audit/
// extractors/ also exists.
func TestExtract_TierCwdSkipsAutoExtract(t *testing.T) {
	cwd := t.TempDir()
	minimalExtractorDir(t, cwd, "typescript")
	t.Chdir(cwd)

	home := fakeHome(t)
	if err := os.MkdirAll(filepath.Join(home, ".config", "audit", "extractors"), 0o755); err != nil {
		t.Fatal(err)
	}

	spy := installEnsureSpy(t, nil)

	var out bytes.Buffer
	Extract(context.Background(), []string{
		"typescript",
		"--root", t.TempDir(),
	}, &out, fstest.MapFS{}) // embedded non-nil so the gate *would* fire on tier 4

	if spy.calls != 0 {
		t.Errorf("EnsureExtractor called %d times for tier Cwd; want 0", spy.calls)
	}
}

// Test 19a — --extractors-dir <empty-path>: tier 1 wins. EnsureExtractor
// is not called even though the resolved dir is empty.
func TestExtract_TierFlagSkipsAutoExtract(t *testing.T) {
	emptyDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(emptyDir, "typescript"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Plant a manifest so Extract gets past manifest.Parse for a clean
	// negative observation; the contents don't matter — we just assert
	// the spy was never called.
	if err := os.WriteFile(
		filepath.Join(emptyDir, "typescript", "manifest.toml"),
		[]byte(`schema_version = 1
[extractor]
name = "typescript"
version = "0.0.1"
[[command]]
catalog = "x"
output_file = "x.json"
invocation = ["sh", "-c", "echo {output}"]
`),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	fakeHome(t)

	spy := installEnsureSpy(t, nil)

	var out bytes.Buffer
	Extract(context.Background(), []string{
		"typescript",
		"--root", t.TempDir(),
		"--extractors-dir", emptyDir,
	}, &out, fstest.MapFS{})

	if spy.calls != 0 {
		t.Errorf("EnsureExtractor called %d times for tier Flag; want 0", spy.calls)
	}
}

// Test 19b — cwd-local extractors/ present but missing the requested
// extractor: tier 2 still wins. EnsureExtractor is not called; Extract
// fails with a "no such extractor / manifest parse" error rather than
// silently bootstrapping into ~/.config/.
func TestExtract_TierCwdMissingExtractorNoAutoExtract(t *testing.T) {
	cwd := t.TempDir()
	minimalExtractorDir(t, cwd, "swift") // present, but the request is for "typescript"
	t.Chdir(cwd)
	fakeHome(t)

	spy := installEnsureSpy(t, nil)

	var out bytes.Buffer
	exit := Extract(context.Background(), []string{
		"typescript",
		"--root", t.TempDir(),
	}, &out, fstest.MapFS{})

	if spy.calls != 0 {
		t.Errorf("EnsureExtractor called %d times when cwd missed extractor; want 0", spy.calls)
	}
	if exit == 0 {
		t.Errorf("expected non-zero exit when manifest is missing, got 0; out=%s", out.String())
	}
}

// Positive companion — tier 4 (ConfigDir): EnsureExtractor IS called.
// Confirms the gate is wired the right way around. We supply a no-op spy
// so the test stays focused on the gate.
func TestExtract_TierConfigDirCallsEnsureExtractor(t *testing.T) {
	home := fakeHome(t)
	configExtractors := filepath.Join(home, ".config", "audit", "extractors")
	minimalExtractorDir(t, filepath.Join(home, ".config", "audit"), "typescript")

	// Ensure no cwd-local extractors/ wins.
	cwd := t.TempDir()
	t.Chdir(cwd)

	if _, err := os.Stat(configExtractors); err != nil {
		t.Fatal(err)
	}

	spy := installEnsureSpy(t, nil)

	var out bytes.Buffer
	Extract(context.Background(), []string{
		"typescript",
		"--root", t.TempDir(),
	}, &out, fstest.MapFS{})

	if spy.calls != 1 {
		t.Errorf("EnsureExtractor called %d times for tier ConfigDir; want 1 (out=%s)", spy.calls, out.String())
	}
	if len(spy.names) > 0 && spy.names[0] != "typescript" {
		t.Errorf("spy received name %q; want typescript", spy.names[0])
	}
}

// Sanity — passing nil embeddedExtractorsFS disables the auto-extract gate
// even on tier 4 (e.g., a test that already populated ~/.config/ doesn't
// want auto-extract running).
func TestExtract_NilEmbeddedFSDisablesAutoExtract(t *testing.T) {
	home := fakeHome(t)
	minimalExtractorDir(t, filepath.Join(home, ".config", "audit"), "typescript")
	cwd := t.TempDir()
	t.Chdir(cwd)

	spy := installEnsureSpy(t, nil)

	var out bytes.Buffer
	Extract(context.Background(), []string{
		"typescript",
		"--root", t.TempDir(),
	}, &out, nil)

	if spy.calls != 0 {
		t.Errorf("EnsureExtractor called %d times with nil embedded FS; want 0", spy.calls)
	}
}

// Keep strings.Contains in scope when only some tests reference it (linter
// hint while the file evolves).
var _ = strings.Contains
