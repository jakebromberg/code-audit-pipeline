package render

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// -update regenerates the golden .md files alongside each fixture.
var update = flag.Bool("update", false, "regenerate golden .md files")

// TestRenderShapes drives every fixture under testdata/<shape>/. For each
// <name>.jsonl, the test reads each line as a row, dispatches it, and
// concatenates the markdown. The result is compared (or written, with -update)
// against testdata/<shape>/<name>.md.
func TestRenderShapes(t *testing.T) {
	for _, shape := range []string{"cluster", "pair", "metric"} {
		shape := shape
		t.Run(shape, func(t *testing.T) {
			entries, err := os.ReadDir(filepath.Join("testdata", shape))
			if err != nil {
				t.Fatalf("read testdata/%s: %v", shape, err)
			}
			for _, e := range entries {
				if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
					continue
				}
				name := strings.TrimSuffix(e.Name(), ".jsonl")
				t.Run(name, func(t *testing.T) {
					runFixture(t, shape, name)
				})
			}
		})
	}
}

func runFixture(t *testing.T, shape, name string) {
	t.Helper()
	jsonlPath := filepath.Join("testdata", shape, name+".jsonl")
	goldenPath := filepath.Join("testdata", shape, name+".md")

	data, err := os.ReadFile(jsonlPath)
	if err != nil {
		t.Fatalf("read %s: %v", jsonlPath, err)
	}

	var blocks []string
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var row Row
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			t.Fatalf("parse line: %v\nline: %s", err, line)
		}
		md, err := Dispatch(row)
		if err != nil {
			t.Fatalf("dispatch: %v", err)
		}
		blocks = append(blocks, md)
	}
	got := strings.Join(blocks, "\n")

	if *update {
		if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden %s: %v", goldenPath, err)
		}
		return
	}

	wantBytes, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read golden %s: %v (run with -update to create)", goldenPath, err)
	}
	if got != string(wantBytes) {
		t.Errorf("render mismatch for %s/%s\n--- got ---\n%s\n--- want ---\n%s",
			shape, name, got, string(wantBytes))
	}
}

// TestDispatchErrors covers the two error paths Dispatch raises: missing
// shape and unknown shape.
func TestDispatchErrors(t *testing.T) {
	t.Run("missing shape", func(t *testing.T) {
		_, err := Dispatch(Row{"cluster_id": "x"})
		if err == nil {
			t.Fatal("expected error for missing shape")
		}
		if !strings.Contains(err.Error(), "missing shape") {
			t.Errorf("unexpected error: %v", err)
		}
	})
	t.Run("unknown shape", func(t *testing.T) {
		_, err := Dispatch(Row{"cluster_id": "x", "shape": "frob"})
		if err == nil {
			t.Fatal("expected error for unknown shape")
		}
		if !strings.Contains(err.Error(), `unknown shape "frob"`) {
			t.Errorf("unexpected error: %v", err)
		}
	})
}

// TestClusterRequiresMembers covers the documented hard-error path: a
// cluster-shape row without a members[] array.
func TestClusterRequiresMembers(t *testing.T) {
	_, err := Cluster(Row{"cluster_id": "x", "shape": "cluster"})
	if err == nil {
		t.Fatal("expected error for missing members")
	}
}

// TestPairRequiresEndpoints covers missing left or right.
func TestPairRequiresEndpoints(t *testing.T) {
	_, err := Pair(Row{"cluster_id": "x", "shape": "pair", "right": map[string]any{}})
	if err == nil || !strings.Contains(err.Error(), "left") {
		t.Errorf("expected left-missing error, got %v", err)
	}
	_, err = Pair(Row{"cluster_id": "x", "shape": "pair", "left": map[string]any{}})
	if err == nil || !strings.Contains(err.Error(), "right") {
		t.Errorf("expected right-missing error, got %v", err)
	}
}
