package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func TestRunBasic(t *testing.T) {
	dir := t.TempDir()
	cat := filepath.Join(dir, "cat.json")
	if err := os.WriteFile(cat, []byte(`{"entries":[{"name":"A"},{"name":"B"}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `.entries[] | .name`,
		InputPath:   cat,
		Out:         &out,
		Raw:         true,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if out.String() != "A\nB\n" {
		t.Errorf("out = %q", out.String())
	}
}

func TestRunWithBindings(t *testing.T) {
	dir := t.TempDir()
	cat := filepath.Join(dir, "cat.json")
	if err := os.WriteFile(cat, []byte(`{"n":10}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `.n + $bonus`,
		InputPath:   cat,
		Bindings:    []Binding{{Name: "bonus", IsJSON: true, Value: float64(5)}},
		Out:         &out,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(out.String()) != "15" {
		t.Errorf("out = %q", out.String())
	}
}

func TestRunWithSlurpfile(t *testing.T) {
	dir := t.TempDir()
	cat := filepath.Join(dir, "cat.json")
	if err := os.WriteFile(cat, []byte(`null`), 0o644); err != nil {
		t.Fatal(err)
	}
	side := filepath.Join(dir, "side.json")
	if err := os.WriteFile(side, []byte(`{"k":"v"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `$side[0].k`,
		InputPath:   "", // -n
		Slurpfiles:  []Slurpfile{{Name: "side", Path: side}},
		Out:         &out,
		Raw:         true,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(out.String()) != "v" {
		t.Errorf("out = %q", out.String())
	}
}

func TestRunReadsEnv(t *testing.T) {
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `$ENV.FOO`,
		InputPath:   "",
		Env:         map[string]string{"FOO": "bar"},
		Out:         &out,
		Raw:         true,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(out.String()) != "bar" {
		t.Errorf("out = %q", out.String())
	}
}

func TestRunWithLibDir(t *testing.T) {
	libdir := t.TempDir()
	if err := os.WriteFile(filepath.Join(libdir, "_canonical.jq"),
		[]byte(`def cluster_id_single_name(p; n): p + ":" + n;`), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `include "_canonical"; cluster_id_single_name("q"; "Foo")`,
		LibDir:      libdir,
		InputPath:   "",
		Out:         &out,
		Raw:         true,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(out.String()) != "q:Foo" {
		t.Errorf("out = %q", out.String())
	}
}

func TestRunWithEmbeddedFS(t *testing.T) {
	embedded := fstest.MapFS{
		"_canonical.jq": &fstest.MapFile{
			Data: []byte(`def cluster_id_single_name(p; n): p + ":" + n;`),
		},
	}
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `include "_canonical"; cluster_id_single_name("emb"; "X")`,
		LibFS:       embedded,
		InputPath:   "",
		Out:         &out,
		Raw:         true,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(out.String()) != "emb:X" {
		t.Errorf("out = %q", out.String())
	}
}

func TestRunRawVsStructured(t *testing.T) {
	dir := t.TempDir()
	cat := filepath.Join(dir, "cat.json")
	if err := os.WriteFile(cat, []byte(`null`), 0o644); err != nil {
		t.Fatal(err)
	}
	var raw, structured bytes.Buffer
	for _, b := range []struct {
		w   *bytes.Buffer
		raw bool
	}{{&raw, true}, {&structured, false}} {
		err := Run(context.Background(), Opts{
			QuerySource: `{"a":1}`,
			InputPath:   cat,
			Out:         b.w,
			Raw:         b.raw,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	// Both should be JSON-encoded since the row is an object, not a string.
	var v1, v2 map[string]any
	if err := json.Unmarshal(raw.Bytes(), &v1); err != nil {
		t.Errorf("raw output not JSON: %v", err)
	}
	if err := json.Unmarshal(structured.Bytes(), &v2); err != nil {
		t.Errorf("structured output not JSON: %v", err)
	}
}

func TestRunStringRaw(t *testing.T) {
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `"hello"`,
		Out:         &out,
		Raw:         true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if out.String() != "hello\n" {
		t.Errorf("out = %q, want hello\\n", out.String())
	}
}

func TestRunSystemJQShellOut(t *testing.T) {
	// Smoke-test the shell-out branch: require system jq present (it is, per
	// pipeline CI). If absent locally, skip.
	if _, err := os.Stat("/usr/bin/jq"); err != nil {
		if _, err := os.Stat("/usr/local/bin/jq"); err != nil {
			if _, err := os.Stat("/opt/homebrew/bin/jq"); err != nil {
				t.Skip("system jq not present")
			}
		}
	}
	dir := t.TempDir()
	qfile := filepath.Join(dir, "q.jq")
	if err := os.WriteFile(qfile, []byte(`.entries[0].name`), 0o644); err != nil {
		t.Fatal(err)
	}
	cat := filepath.Join(dir, "cat.json")
	if err := os.WriteFile(cat, []byte(`{"entries":[{"name":"X"}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := Run(context.Background(), Opts{
		QuerySource: `placeholder`,
		QueryFile:   qfile,
		InputPath:   cat,
		Out:         &out,
		Raw:         true,
		UseSystemJQ: true,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.TrimSpace(out.String()) != "X" {
		t.Errorf("out = %q", out.String())
	}
}
