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
		if shape == "cluster" {
			members, ok := r["members"].([]interface{})
			if !ok || len(members) == 0 {
				t.Errorf("cluster row missing/empty members: %v", r)
			}
		}
	}
}

func TestFindNextInstanceAcceptsBareArrayCatalog(t *testing.T) {
	// The Swift extractor emits bare arrays, not envelope-wrapped catalogs
	// (extractors/swift/Sources/swift-catalog/main.swift writeJSON([…])).
	// find-next-instance must accept that shape — otherwise the subcommand
	// is unusable against any Swift catalog produced by the bundled tool.
	tmp := t.TempDir()
	bareFn := tmp + "/fn.json"
	if err := writeFile(bareFn, `[
	  {"name":"Foo.bar","kind":"method","package":"P","file":"a.swift","line":10,
	   "body_hash":"x","body_line_count":3,
	   "body_lines":["line one","line three","line two"],
	   "generated":false,"is_test":false}
	]`); err != nil {
		t.Fatal(err)
	}
	bareTy := tmp + "/ty.json"
	if err := writeFile(bareTy, `[]`); err != nil {
		t.Fatal(err)
	}
	diff := tmp + "/d.diff"
	if err := writeFile(diff,
		"diff --git a/x.swift b/x.swift\n"+
			"--- a/x.swift\n"+
			"+++ b/x.swift\n"+
			"@@ -1,3 +1,1 @@\n"+
			"-line one\n"+
			"-line two\n"+
			"-line three\n"+
			"+merged\n",
	); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", diff,
		"--function-catalog", bareFn,
		"--type-catalog", bareTy,
		"--format", "jsonl",
		"--min-jaccard", "0.5",
	}, &out)
	if exit != 0 {
		t.Fatalf("bare-array catalog rejected: exit=%d out=%s", exit, out.String())
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) == 0 {
		t.Errorf("want match against bare-array catalog row, got none: %s", out.String())
	}
}

func TestFindNextInstanceClusterIDDistinguishesHunks(t *testing.T) {
	// Two distinct hunks in the same source function, both matching the
	// same candidate function, must produce distinct cluster_ids — the
	// within-query uniqueness invariant. Folding the hunk anchor into the
	// cluster_id is what gives this.
	tmp := t.TempDir()
	fnCat := tmp + "/fn.json"
	if err := writeFile(fnCat, `{"schema_version":"1.1","entries":[
	  {"name":"Src","kind":"function","package":"P","file":"src.go","line":10,
	   "body_hash":"x","body_line_count":50,
	   "body_lines":["a","b","c","d"],
	   "generated":false,"is_test":false},
	  {"name":"Cand","kind":"function","package":"Q","file":"q.go","line":1,
	   "body_hash":"y","body_line_count":4,
	   "body_lines":["a","b","c","d"],
	   "generated":false,"is_test":false}
	]}`); err != nil {
		t.Fatal(err)
	}
	tyCat := tmp + "/ty.json"
	if err := writeFile(tyCat, `[]`); err != nil {
		t.Fatal(err)
	}
	// Two hunks at different positions, both inside Src's body span [10,60),
	// both removing the same three lines that match Cand's body.
	diff := tmp + "/d.diff"
	if err := writeFile(diff,
		"diff --git a/src.go b/src.go\n"+
			"--- a/src.go\n"+
			"+++ b/src.go\n"+
			"@@ -15,4 +15,1 @@\n"+
			"-a\n"+
			"-b\n"+
			"-c\n"+
			"+merged\n"+
			"@@ -40,4 +37,1 @@\n"+
			"-a\n"+
			"-b\n"+
			"-c\n"+
			"+merged2\n",
	); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", diff,
		"--function-catalog", fnCat,
		"--type-catalog", tyCat,
		"--format", "jsonl",
		"--min-jaccard", "0.5",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d out=%s", exit, out.String())
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) != 2 {
		t.Fatalf("want 2 rows (one per hunk), got %d: %s", len(rows), out.String())
	}
	a, _ := rows[0]["cluster_id"].(string)
	b, _ := rows[1]["cluster_id"].(string)
	if a == "" || b == "" {
		t.Fatalf("missing cluster_id: %v %v", a, b)
	}
	if a == b {
		t.Errorf("cluster_ids collide for two-hunks-same-pair: %q", a)
	}
}

func TestFindNextInstanceMembersCarryInlineFields(t *testing.T) {
	// renderMember consumes async, param_count, touched_in_window; the
	// outRow's member maps must carry them so the shared renderer can
	// annotate. Regression for finding #10 (5-field projection).
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", "testdata/findnext/pr.diff",
		"--function-catalog", "testdata/findnext/function-catalog.json",
		"--type-catalog", "testdata/findnext/type-catalog.json",
		"--format", "jsonl",
		"--kind", "function-body",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d", exit)
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) == 0 {
		t.Fatal("want at least one row")
	}
	for _, r := range rows {
		var member map[string]interface{}
		switch r["shape"] {
		case "pair":
			member, _ = r["right"].(map[string]interface{})
		case "cluster":
			ms, _ := r["members"].([]interface{})
			if len(ms) > 0 {
				member, _ = ms[0].(map[string]interface{})
			}
		}
		if member == nil {
			t.Errorf("row %v missing candidate member", r["cluster_id"])
			continue
		}
		for _, k := range []string{"async", "param_count", "touched_in_window", "is_test", "generated"} {
			if _, ok := member[k]; !ok {
				t.Errorf("member missing %q (needed for render.Pair / renderMember): %v", k, member)
			}
		}
	}
}

func TestFindNextInstanceFiltersGeneratedAndTest(t *testing.T) {
	// Generated rows and test-file rows should never appear as candidates.
	tmp := t.TempDir()
	fnCat := tmp + "/fn.json"
	if err := writeFile(fnCat, `{"schema_version":"1.1","entries":[
	  {"name":"Real","kind":"function","package":"P","file":"a.go","line":1,
	   "body_hash":"r","body_line_count":3,"body_lines":["x","y","z"],
	   "generated":false,"is_test":false},
	  {"name":"Gen","kind":"function","package":"P","file":"gen.go","line":1,
	   "body_hash":"g","body_line_count":3,"body_lines":["x","y","z"],
	   "generated":true,"is_test":false},
	  {"name":"Test","kind":"function","package":"P","file":"a_test.go","line":1,
	   "body_hash":"t","body_line_count":3,"body_lines":["x","y","z"],
	   "generated":false,"is_test":true}
	]}`); err != nil {
		t.Fatal(err)
	}
	tyCat := tmp + "/ty.json"
	if err := writeFile(tyCat, `[]`); err != nil {
		t.Fatal(err)
	}
	diff := tmp + "/d.diff"
	if err := writeFile(diff,
		"diff --git a/src.go b/src.go\n"+
			"--- a/src.go\n"+
			"+++ b/src.go\n"+
			"@@ -1,4 +1,1 @@\n"+
			"-x\n"+
			"-y\n"+
			"-z\n"+
			"+merged\n",
	); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", diff,
		"--function-catalog", fnCat,
		"--type-catalog", tyCat,
		"--format", "jsonl",
		"--min-jaccard", "0.5",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d out=%s", exit, out.String())
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) != 1 {
		t.Fatalf("want exactly 1 (Real, not Gen/Test), got %d: %s", len(rows), out.String())
	}
	members, _ := rows[0]["members"].([]interface{})
	if len(members) == 0 {
		t.Fatalf("expected single-member cluster row, got %v", rows[0])
	}
	m, _ := members[0].(map[string]interface{})
	if m["name"] != "Real" {
		t.Errorf("expected Real, got %v", m["name"])
	}
}

func TestFindNextInstanceEnclosingFunctionRangeOverlap(t *testing.T) {
	// A hunk between two function bodies must NOT be misattributed to the
	// prior function. Regression for finding #4: enclosingFunction now
	// requires the function's body span to overlap the hunk range.
	tmp := t.TempDir()
	fnCat := tmp + "/fn.json"
	// Function A at line 10 (body 3 lines → spans [10,13)), function B at
	// line 50 (body 3 lines → [50,53)). Hunk at lines 20-22 lives between
	// them — should resolve to NO enclosing function and emit shape:cluster.
	if err := writeFile(fnCat, `{"schema_version":"1.1","entries":[
	  {"name":"A","kind":"function","package":"P","file":"x.go","line":10,
	   "body_hash":"a","body_line_count":3,"body_lines":["a1","a2","a3"],
	   "generated":false,"is_test":false},
	  {"name":"B","kind":"function","package":"P","file":"x.go","line":50,
	   "body_hash":"b","body_line_count":3,"body_lines":["b1","b2","b3"],
	   "generated":false,"is_test":false},
	  {"name":"Cand","kind":"function","package":"Q","file":"q.go","line":1,
	   "body_hash":"c","body_line_count":3,"body_lines":["mid1","mid2","mid3"],
	   "generated":false,"is_test":false}
	]}`); err != nil {
		t.Fatal(err)
	}
	tyCat := tmp + "/ty.json"
	if err := writeFile(tyCat, `[]`); err != nil {
		t.Fatal(err)
	}
	diff := tmp + "/d.diff"
	if err := writeFile(diff,
		"diff --git a/x.go b/x.go\n"+
			"--- a/x.go\n"+
			"+++ b/x.go\n"+
			"@@ -20,4 +20,1 @@\n"+
			"-mid1\n"+
			"-mid2\n"+
			"-mid3\n"+
			"+merged\n",
	); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", diff,
		"--function-catalog", fnCat,
		"--type-catalog", tyCat,
		"--format", "jsonl",
		"--min-jaccard", "0.5",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d out=%s", exit, out.String())
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d: %s", len(rows), out.String())
	}
	if shape := rows[0]["shape"]; shape != "cluster" {
		t.Errorf("want shape=cluster (no enclosing function), got %v", shape)
	}
	if _, ok := rows[0]["left"]; ok {
		t.Errorf("between-functions hunk must not surface left attribution: %v", rows[0])
	}
}

func TestFindNextInstanceSelfMatchActuallySuppresses(t *testing.T) {
	// Real self-match guard test: catalog row whose body shares lines with
	// the removed set AND lives at the same (file, line) as the PR's edited
	// scope. Without the guard, the function would self-match. The fixture
	// catalog reflects a pre-PR state for the edited row so the body_lines
	// genuinely overlap.
	tmp := t.TempDir()
	fnCat := tmp + "/fn.json"
	if err := writeFile(fnCat, `{"schema_version":"1.1","entries":[
	  {"name":"Edited","kind":"function","package":"P","file":"src.go","line":10,
	   "body_hash":"e","body_line_count":4,
	   "body_lines":["common1","common2","common3","extra"],
	   "generated":false,"is_test":false},
	  {"name":"Other","kind":"function","package":"P","file":"other.go","line":1,
	   "body_hash":"o","body_line_count":3,
	   "body_lines":["common1","common2","common3"],
	   "generated":false,"is_test":false}
	]}`); err != nil {
		t.Fatal(err)
	}
	tyCat := tmp + "/ty.json"
	if err := writeFile(tyCat, `[]`); err != nil {
		t.Fatal(err)
	}
	diff := tmp + "/d.diff"
	if err := writeFile(diff,
		"diff --git a/src.go b/src.go\n"+
			"--- a/src.go\n"+
			"+++ b/src.go\n"+
			"@@ -10,4 +10,1 @@\n"+
			"-common1\n"+
			"-common2\n"+
			"-common3\n"+
			"+merged\n",
	); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	exit := FindNextInstance(context.Background(), []string{
		"--diff", diff,
		"--function-catalog", fnCat,
		"--type-catalog", tyCat,
		"--format", "jsonl",
		"--min-jaccard", "0.5",
	}, &out)
	if exit != 0 {
		t.Fatalf("exit=%d out=%s", exit, out.String())
	}
	rows := decodeRows(t, out.Bytes())
	if len(rows) != 1 {
		t.Fatalf("want exactly 1 candidate (Other, not Edited self-match), got %d: %s", len(rows), out.String())
	}
	right, _ := rows[0]["right"].(map[string]interface{})
	if right == nil {
		t.Fatalf("want pair row with right{}; got %v", rows[0])
	}
	if right["name"] == "Edited" {
		t.Errorf("self-match guard failed: %v", rows[0])
	}
	if right["name"] != "Other" {
		t.Errorf("expected Other, got %v", right["name"])
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
