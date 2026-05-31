package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestFindNextInstanceJSONLFunctionBodyMatch(t *testing.T) {
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--function-catalog", "testdata/findnext/function-catalog.json",
		"--type-catalog", "testdata/findnext/type-catalog.json",
		"--kind", "function-body",
		"--min-match-lines", "3",
		"--min-jaccard", "0.5",
		"--format", "jsonl",
		"--pr", "208",
		"--repo", "wxyc/wxyc-ios-64",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d, out=%s", exit, out.String())
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) == 0 {
		t.Fatalf("want >= 1 row, got 0 (out=%s)", out.String())
	}
	// Onboarding.setUpAnalytics should be present, Bootstrap.setUpAnalytics
	// excluded by the self-match filter.
	found := false
	for _, r := range rows {
		right, _ := r["right"].(map[string]interface{})
		name, _ := right["name"].(string)
		if name == "Bootstrap.setUpAnalytics" {
			t.Errorf("self-match leaked into output: %v", r)
		}
		if name == "Onboarding.setUpAnalytics" {
			found = true
			if r["match_kind"] != "function-body" {
				t.Errorf("wrong match_kind: %v", r["match_kind"])
			}
			if r["shape"] != "pair" {
				t.Errorf("wrong shape: %v want pair", r["shape"])
			}
			if r["query"] != "find-next-instance" {
				t.Errorf("wrong query: %v", r["query"])
			}
			if r["pr_number"].(float64) != 208 {
				t.Errorf("wrong pr_number: %v", r["pr_number"])
			}
			if r["pr_repo"] != "wxyc/wxyc-ios-64" {
				t.Errorf("wrong pr_repo: %v", r["pr_repo"])
			}
			left, _ := r["left"].(map[string]interface{})
			if left["name"] != "Bootstrap.setUpAnalytics" {
				t.Errorf("left should be PR-source (Bootstrap), got %v", left["name"])
			}
		}
	}
	if !found {
		t.Errorf("Onboarding.setUpAnalytics not found in output:\n%s", out.String())
	}
}

func TestFindNextInstanceJSONLTypeShapeMatch(t *testing.T) {
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--function-catalog", "testdata/findnext/function-catalog.json",
		"--type-catalog", "testdata/findnext/type-catalog.json",
		"--kind", "type-shape",
		"--format", "jsonl",
		"--pr", "208",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d, out=%s", exit, out.String())
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) == 0 {
		t.Fatalf("want >= 1 row, got 0 (out=%s)", out.String())
	}
	found := false
	for _, r := range rows {
		right, _ := r["right"].(map[string]interface{})
		name, _ := right["name"].(string)
		if name == "PlaybackSession" {
			t.Errorf("self-match leaked: %v", r)
		}
		if name == "PlaybackBookmark" {
			found = true
			if r["match_kind"] != "type-shape" {
				t.Errorf("wrong match_kind: %v", r["match_kind"])
			}
		}
	}
	if !found {
		t.Errorf("PlaybackBookmark not in output:\n%s", out.String())
	}
}

func TestFindNextInstanceTextHeader(t *testing.T) {
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--function-catalog", "testdata/findnext/function-catalog.json",
		"--type-catalog", "testdata/findnext/type-catalog.json",
		"--format", "text",
		"--pr", "208",
		"--repo", "wxyc/wxyc-ios-64",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d, out=%s", exit, out.String())
	}
	if !strings.Contains(out.String(), "PR #208") {
		t.Errorf("text output missing PR header: %s", out.String())
	}
	if !strings.Contains(out.String(), "wxyc/wxyc-ios-64") {
		t.Errorf("text output missing repo: %s", out.String())
	}
}

func TestFindNextInstanceRequiresPROrDiff(t *testing.T) {
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--format", "text",
	}, &out)
	if exit != 2 {
		t.Errorf("want exit=2, got %d (out=%s)", exit, out.String())
	}
	if !strings.Contains(out.String(), "--pr or --diff is required") {
		t.Errorf("missing usage message: %s", out.String())
	}
}

func TestFindNextInstanceRejectsBadFormat(t *testing.T) {
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--format", "csv",
	}, &out)
	if exit != 2 {
		t.Errorf("want exit=2, got %d", exit)
	}
}

func TestFindNextInstanceRejectsBadKind(t *testing.T) {
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--kind", "wat",
	}, &out)
	if exit != 2 {
		t.Errorf("want exit=2, got %d", exit)
	}
}

func TestFindNextInstanceRejectsBadSchemaVersion(t *testing.T) {
	tmp := t.TempDir()
	bad := tmp + "/bad-fn.json"
	if err := writeFile(bad, `{"schema_version":"0.9","entries":[]}`); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--function-catalog", bad,
		"--type-catalog", "testdata/findnext/type-catalog.json",
		"--kind", "function-body",
	}, &out)
	if exit != 3 {
		t.Errorf("want exit=3 (catalog error), got %d (out=%s)", exit, out.String())
	}
	if !strings.Contains(out.String(), "schema_version") {
		t.Errorf("missing schema_version note: %s", out.String())
	}
}

func TestFindNextInstancePairRowsHaveCatalogShapedSides(t *testing.T) {
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--function-catalog", "testdata/findnext/function-catalog.json",
		"--type-catalog", "testdata/findnext/type-catalog.json",
		"--format", "jsonl",
		"--pr", "208",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d", exit)
	}
	rows := decodeRows(t, out.Bytes())
	for _, r := range rows {
		shape, _ := r["shape"].(string)
		if shape != "pair" && shape != "metric" {
			t.Errorf("unexpected shape: %v", shape)
		}
		if shape == "pair" {
			for _, side := range []string{"left", "right"} {
				m, ok := r[side].(map[string]interface{})
				if !ok {
					t.Errorf("pair row missing %s{}: %v", side, r)
					continue
				}
				for _, key := range []string{"name", "kind", "package", "file", "line"} {
					if _, ok := m[key]; !ok {
						t.Errorf("pair %s missing %s: %v", side, key, m)
					}
				}
			}
		}
		if shape == "metric" {
			if _, ok := r["left"]; ok {
				t.Errorf("metric row should not carry left: %v", r)
			}
		}
	}
}

func decodeRows(t *testing.T, data []byte) []map[string]interface{} {
	t.Helper()
	var out []map[string]interface{}
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		var row map[string]interface{}
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			t.Fatalf("decode %q: %v", line, err)
		}
		out = append(out, row)
	}
	return out
}

func writeFile(path, body string) error {
	return os.WriteFile(path, []byte(body), 0o644)
}
