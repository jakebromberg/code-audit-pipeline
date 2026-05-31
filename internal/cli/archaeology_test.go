package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestArchaeologyOfflineEndToEnd runs the CLI against a synthetic root in
// `--no-issues --no-prs` mode (so no gh calls happen) and verifies the
// resulting archaeology.json is well-formed with the file-system sources
// populated.
func TestArchaeologyOfflineEndToEnd(t *testing.T) {
	root := t.TempDir()
	mustWrite(t, filepath.Join(root, "CLAUDE.md"), "# Repo rules\nbe nice\n")
	mustWrite(t, filepath.Join(root, "Shared", "Core", "CLAUDE.md"), "core rules\n")
	mustWrite(t, filepath.Join(root, "docs", "adr", "0001-foo.md"),
		"# ADR 0001: Foo\n\nStatus: accepted\n\nBody.\n")
	mustWrite(t, filepath.Join(root, "internal", "demo.go"),
		"package demo\n\n// TODO bake bread\nfunc Demo() {}\n")
	mustWrite(t, filepath.Join(root, "Old.swift"),
		"@available(*, deprecated, message: \"use New\")\nfunc old() {}\n")

	var stdout bytes.Buffer
	rc := Archaeology(context.Background(), []string{
		"--root", root,
		"--no-issues",
		"--no-prs",
	}, &stdout)
	if rc != 0 {
		t.Fatalf("exit=%d, stdout=%q", rc, stdout.String())
	}

	outPath := strings.TrimSpace(stdout.String())
	if outPath == "" {
		t.Fatal("stdout did not carry the output path")
	}
	if !strings.HasSuffix(outPath, "archaeology.json") {
		t.Errorf("unexpected output path: %q", outPath)
	}

	data, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read bundle: %v", err)
	}
	var bundle map[string]any
	if err := json.Unmarshal(data, &bundle); err != nil {
		t.Fatalf("bundle not valid JSON: %v", err)
	}

	if bundle["schema_version"] != "1" {
		t.Errorf("schema_version=%v", bundle["schema_version"])
	}
	sources, _ := bundle["sources"].(map[string]any)
	if sources == nil {
		t.Fatal("sources missing")
	}
	for _, kind := range []string{"open_issues", "recent_prs"} {
		p, _ := sources[kind].(map[string]any)
		if p == nil || p["skipped"] != true {
			t.Errorf("%s not marked skipped: %+v", kind, p)
		}
	}
	for _, kind := range []string{"todos", "deprecations", "adrs", "rule_text"} {
		p, _ := sources[kind].(map[string]any)
		if p == nil || p["ok"] != true {
			t.Errorf("%s not ok: %+v", kind, p)
		}
		if p["count"].(float64) < 1 {
			t.Errorf("%s count=%v (want >=1)", kind, p["count"])
		}
	}

	// Spot-check a TODO row.
	todos, _ := bundle["todos"].([]any)
	if len(todos) != 1 {
		t.Fatalf("todos len=%d", len(todos))
	}
	td, _ := todos[0].(map[string]any)
	if td["text"] != "bake bread" {
		t.Errorf("todo text=%v", td["text"])
	}

	// Diff-spill directory exists.
	diffDir := filepath.Join(root, ".audit", "archaeology", "prs")
	if _, err := os.Stat(diffDir); err != nil {
		t.Errorf("diff dir not created: %v", err)
	}
}

func TestArchaeologyRejectsUnknownFlag(t *testing.T) {
	var stdout bytes.Buffer
	rc := Archaeology(context.Background(), []string{"--no-such-flag"}, &stdout)
	if rc != 2 {
		t.Errorf("exit=%d want 2", rc)
	}
}

func TestArchaeologyCustomOutputPath(t *testing.T) {
	root := t.TempDir()
	mustWrite(t, filepath.Join(root, "CLAUDE.md"), "rules")
	outPath := filepath.Join(t.TempDir(), "bundle.json")

	var stdout bytes.Buffer
	rc := Archaeology(context.Background(), []string{
		"--root", root,
		"--output", outPath,
		"--no-issues", "--no-prs", "--no-todos", "--no-deprecations", "--no-adrs",
	}, &stdout)
	if rc != 0 {
		t.Fatalf("exit=%d", rc)
	}
	if _, err := os.Stat(outPath); err != nil {
		t.Errorf("bundle not written at --output path: %v", err)
	}
}

func mustWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
