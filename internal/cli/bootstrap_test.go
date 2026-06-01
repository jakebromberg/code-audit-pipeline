package cli

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/fstest"
	"time"
)

// embeddedExtractor builds a fstest.MapFS shaped like a single embedded
// extractor (rooted *above* the extractor; matches what
// embeddedExtractors() returns). manifestExtras is appended verbatim to
// the manifest body — pass "" for the default, or
// `bootstrap = ["sh", "-c", "echo ok"]` to wire bootstrap.
func embeddedExtractor(t *testing.T, name, manifestExtras string) fstest.MapFS {
	t.Helper()
	body := `schema_version = 2
[extractor]
name = "` + name + `"
version = "0.0.1"
[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["node", "type-catalog.mjs", "--output", "{output}"]

[runtime]
requires = ["node >= 18"]
` + manifestExtras
	return fstest.MapFS{
		name + "/manifest.toml":      &fstest.MapFile{Data: []byte(body), Mode: 0o444},
		name + "/type-catalog.mjs":   &fstest.MapFile{Data: []byte("// extractor\n"), Mode: 0o444},
	}
}

// Test 13 — fresh ~/.config/audit/extractors/ empty: EnsureExtractor lays
// down source, runs bootstrap, records state.json as ok.
func TestEnsureExtractor_FreshTriggersBootstrap(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(t.TempDir(), "bootstrap-witness")
	emb := embeddedExtractor(t, "typescript",
		`bootstrap = ["sh", "-c", "touch `+sentinel+`"]
setup_hint = "manual install fallback"
`)

	var out bytes.Buffer
	err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out)
	if err != nil {
		t.Fatalf("EnsureExtractor: %v (out=%s)", err, out.String())
	}
	if _, err := os.Stat(filepath.Join(extractorsRoot, "typescript", "type-catalog.mjs")); err != nil {
		t.Errorf("source not laid down: %v", err)
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Errorf("bootstrap did not run: %v", err)
	}

	state, err := loadState(auditDest)
	if err != nil {
		t.Fatal(err)
	}
	got := state.Extractors["typescript"]
	if got.BootstrapStatus != BootstrapOK {
		t.Errorf("status = %q, want %q", got.BootstrapStatus, BootstrapOK)
	}
	if got.SourceSHA == "" {
		t.Error("SourceSHA should be populated after success")
	}
}

// Test 14 — second EnsureExtractor with no source changes is a no-op: no
// bootstrap re-run, no file writes.
func TestEnsureExtractor_IdempotentNoOp(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(t.TempDir(), "bootstrap-witness")
	emb := embeddedExtractor(t, "typescript",
		`bootstrap = ["sh", "-c", "touch `+sentinel+`"]
`)

	var out bytes.Buffer
	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out); err != nil {
		t.Fatalf("first EnsureExtractor: %v", err)
	}
	first, err := os.Stat(sentinel)
	if err != nil {
		t.Fatal(err)
	}

	time.Sleep(10 * time.Millisecond)

	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out); err != nil {
		t.Fatalf("second EnsureExtractor: %v", err)
	}
	second, err := os.Stat(sentinel)
	if err != nil {
		t.Fatal(err)
	}
	if !second.ModTime().Equal(first.ModTime()) {
		t.Errorf("idempotent EnsureExtractor re-ran bootstrap: first=%v second=%v",
			first.ModTime(), second.ModTime())
	}
}

// Test 15 — stale CLEAN files auto-upgrade silently; bootstrap re-runs.
func TestEnsureExtractor_StaleCleanUpgradesSilently(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	counter := filepath.Join(t.TempDir(), "counter")
	embV1 := embeddedExtractor(t, "typescript",
		`bootstrap = ["sh", "-c", "printf x >> `+counter+`"]
`)

	var out bytes.Buffer
	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, embV1, &out); err != nil {
		t.Fatalf("v1: %v", err)
	}
	c1, _ := os.ReadFile(counter)

	// Simulate "source moved" by mutating the embedded FS — change the script body.
	embV2 := embeddedExtractor(t, "typescript",
		`bootstrap = ["sh", "-c", "printf x >> `+counter+`"]
`)
	embV2["typescript/type-catalog.mjs"] = &fstest.MapFile{
		Data: []byte("// extractor v2\n"),
		Mode: 0o444,
	}

	// Re-ensure with the new embedded FS.
	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, embV2, &out); err != nil {
		t.Fatalf("v2: %v", err)
	}
	c2, _ := os.ReadFile(counter)
	if len(c2) <= len(c1) {
		t.Errorf("bootstrap did not re-run on stale CLEAN upgrade: c1=%d c2=%d", len(c1), len(c2))
	}

	got, _ := os.ReadFile(filepath.Join(extractorsRoot, "typescript", "type-catalog.mjs"))
	if string(got) != "// extractor v2\n" {
		t.Errorf("file not upgraded: %q", string(got))
	}

	// Idempotent on re-run with v2.
	c2Before := len(c2)
	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, embV2, &out); err != nil {
		t.Fatalf("v2 again: %v", err)
	}
	c3, _ := os.ReadFile(counter)
	if len(c3) != c2Before {
		t.Errorf("post-upgrade EnsureExtractor not idempotent: c2=%d c3=%d", c2Before, len(c3))
	}
}

// Test 16 — stale DIRTY files: warn but do not overwrite; do not re-run
// bootstrap solely because of the dirty file.
func TestEnsureExtractor_StaleDirtyPreservesAndWarns(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	counter := filepath.Join(t.TempDir(), "counter")
	emb := embeddedExtractor(t, "typescript",
		`bootstrap = ["sh", "-c", "printf x >> `+counter+`"]
`)

	var out bytes.Buffer
	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out); err != nil {
		t.Fatalf("first: %v", err)
	}

	// Locally edit a file.
	target := filepath.Join(extractorsRoot, "typescript", "type-catalog.mjs")
	if err := os.WriteFile(target, []byte("// LOCALLY EDITED\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	out.Reset()
	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out); err != nil {
		t.Fatalf("second: %v", err)
	}
	preserved, _ := os.ReadFile(target)
	if string(preserved) != "// LOCALLY EDITED\n" {
		t.Errorf("DIRTY file was overwritten: %q", string(preserved))
	}
	if !strings.Contains(out.String(), "locally modified") {
		t.Errorf("expected DIRTY warning, got: %s", out.String())
	}
}

// Test 17 — two concurrent EnsureExtractor calls on a fresh install:
// exactly one bootstrap invocation across both callers.
func TestEnsureExtractor_ConcurrentSingleBootstrap(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	counter := filepath.Join(t.TempDir(), "counter")
	emb := embeddedExtractor(t, "typescript",
		`bootstrap = ["sh", "-c", "printf x >> `+counter+`"]
`)

	var (
		wg     sync.WaitGroup
		errs   [2]error
		start  = make(chan struct{})
	)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			<-start
			var out bytes.Buffer
			errs[idx] = EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out)
		}(i)
	}
	close(start)
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: %v", i, err)
		}
	}
	data, _ := os.ReadFile(counter)
	if len(data) != 1 {
		t.Errorf("expected exactly 1 bootstrap invocation across both callers, got %d", len(data))
	}
}

// Test 17a — first EnsureExtractor's bootstrap fails: state.json records
// failed before lock release; second call sees failed and retries.
func TestEnsureExtractor_RetriesAfterFailure(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	failTrigger := filepath.Join(t.TempDir(), "fail-while-this-exists")
	if err := os.WriteFile(failTrigger, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// bootstrap exits 1 while the trigger file is present, 0 otherwise.
	emb := embeddedExtractor(t, "typescript", fmt.Sprintf(
		`bootstrap = ["sh", "-c", "if [ -f %s ]; then exit 1; fi; exit 0"]
setup_hint = "hint here"
`, failTrigger))

	var out bytes.Buffer
	err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out)
	if err == nil {
		t.Fatal("expected failure on first call")
	}

	state, _ := loadState(auditDest)
	if state.Extractors["typescript"].BootstrapStatus != BootstrapFailed {
		t.Errorf("status = %q, want %q after first failure",
			state.Extractors["typescript"].BootstrapStatus, BootstrapFailed)
	}
	if !strings.Contains(out.String(), "hint here") {
		t.Errorf("expected setup_hint surfaced on failure: %s", out.String())
	}

	// Now remove the trigger and retry — bootstrap should succeed.
	os.Remove(failTrigger)
	out.Reset()
	if err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out); err != nil {
		t.Fatalf("second call: %v", err)
	}
	state, _ = loadState(auditDest)
	if state.Extractors["typescript"].BootstrapStatus != BootstrapOK {
		t.Errorf("status = %q, want %q after recovery",
			state.Extractors["typescript"].BootstrapStatus, BootstrapOK)
	}
}

// Test 18 — bootstrap failure persists in state.json with LastError. Same
// fixture as 17a but asserts the LastError content.
func TestEnsureExtractor_PersistsFailureLastError(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	emb := embeddedExtractor(t, "typescript",
		`bootstrap = ["sh", "-c", "echo MARKER_BOOM >&2; exit 9"]
`)

	var out bytes.Buffer
	_ = EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, emb, &out)
	state, _ := loadState(auditDest)
	got := state.Extractors["typescript"]
	if got.BootstrapStatus != BootstrapFailed {
		t.Errorf("status = %q, want %q", got.BootstrapStatus, BootstrapFailed)
	}
	if !strings.Contains(got.LastError, "MARKER_BOOM") {
		t.Errorf("LastError should capture stderr: %q", got.LastError)
	}
}

// Test 18a — malformed manifest causes EnsureExtractor to return the
// parse error and *not* persist state.Extractors entry (the file-copy
// loop ran, but state.json's Extractors map stays empty).
func TestEnsureExtractor_MalformedManifestNoStateMutation(t *testing.T) {
	tmp := t.TempDir()
	auditDest := filepath.Join(tmp, "audit-home")
	extractorsRoot := filepath.Join(auditDest, "extractors")
	if err := os.MkdirAll(extractorsRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	// Schema 99 — out of supported range; manifest.Parse will reject.
	bad := fstest.MapFS{
		"typescript/manifest.toml": &fstest.MapFile{
			Data: []byte("schema_version = 99\n"),
			Mode: 0o444,
		},
		"typescript/type-catalog.mjs": &fstest.MapFile{Data: []byte("// hi\n"), Mode: 0o444},
	}

	var out bytes.Buffer
	err := EnsureExtractor(context.Background(), "typescript", extractorsRoot, auditDest, bad, &out)
	if err == nil {
		t.Fatal("expected parse error, got nil")
	}
	if !strings.Contains(err.Error(), "schema_version") {
		t.Errorf("error should mention schema_version: %v", err)
	}
	state, _ := loadState(auditDest)
	if state != nil {
		if _, ok := state.Extractors["typescript"]; ok {
			t.Errorf("malformed manifest should leave state.Extractors empty for this name, got %+v", state.Extractors["typescript"])
		}
	}
}

// Use atomic to silence the "unused import" linter when the file is built
// without test 17 in scope.
var _ = atomic.AddInt32
