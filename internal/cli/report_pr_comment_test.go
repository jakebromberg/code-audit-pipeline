package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
	"github.com/jakebromberg/code-audit-pipeline/internal/render"
)

func TestLoadTouchedSet(t *testing.T) {
	dir := t.TempDir()

	t.Run("valid array", func(t *testing.T) {
		path := filepath.Join(dir, "touched.json")
		write(t, path, `["src/foo.ts", "src/bar.ts"]`)
		got, err := loadTouchedSet(path)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if _, ok := got["src/foo.ts"]; !ok {
			t.Errorf("missing src/foo.ts")
		}
		if _, ok := got["src/bar.ts"]; !ok {
			t.Errorf("missing src/bar.ts")
		}
	})

	t.Run("normalizes entries", func(t *testing.T) {
		path := filepath.Join(dir, "normalize.json")
		write(t, path, `["./src/foo.ts", "src\\bar.ts", " src/baz.ts\r"]`)
		got, err := loadTouchedSet(path)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		for _, want := range []string{"src/foo.ts", "src/bar.ts", "src/baz.ts"} {
			if _, ok := got[want]; !ok {
				t.Errorf("missing normalized entry %q (set: %v)", want, got)
			}
		}
	})

	t.Run("empty array returns empty non-nil set", func(t *testing.T) {
		path := filepath.Join(dir, "empty.json")
		write(t, path, `[]`)
		got, err := loadTouchedSet(path)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got == nil {
			t.Fatalf("got nil set; want non-nil empty set")
		}
		if len(got) != 0 {
			t.Errorf("got %d entries; want 0", len(got))
		}
	})

	t.Run("missing file is caller error", func(t *testing.T) {
		_, err := loadTouchedSet(filepath.Join(dir, "does-not-exist.json"))
		if err == nil {
			t.Fatal("want error for missing file")
		}
	})

	t.Run("malformed JSON is caller error", func(t *testing.T) {
		path := filepath.Join(dir, "bad.json")
		write(t, path, `{not json`)
		_, err := loadTouchedSet(path)
		if err == nil {
			t.Fatal("want error for malformed JSON")
		}
	})

	t.Run("non-array top-level is caller error", func(t *testing.T) {
		path := filepath.Join(dir, "obj.json")
		write(t, path, `{"a": "b"}`)
		_, err := loadTouchedSet(path)
		if err == nil {
			t.Fatal("want error for object top-level")
		}
	})

	t.Run("non-string element cites index", func(t *testing.T) {
		path := filepath.Join(dir, "mixed.json")
		write(t, path, `["src/foo.ts", 42, "src/bar.ts"]`)
		_, err := loadTouchedSet(path)
		if err == nil {
			t.Fatal("want error for non-string element")
		}
		if !strings.Contains(err.Error(), "[1]") {
			t.Errorf("error %q should cite element index [1]", err)
		}
	})

	t.Run("whitespace-only string is dropped silently", func(t *testing.T) {
		path := filepath.Join(dir, "whitespace.json")
		write(t, path, `["src/foo.ts", "   ", "src/bar.ts"]`)
		got, err := loadTouchedSet(path)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(got) != 2 {
			t.Errorf("got %d entries; want 2 (whitespace-only dropped)", len(got))
		}
	})
}

func TestFilterRowsByTouched_NilTouched(t *testing.T) {
	// touched == nil short-circuits to pass-through.
	rows := []render.Row{clusterRow("c1", []map[string]any{{"file": "a.ts"}})}
	header := &frontmatter.Header{Shape: []string{"cluster"}}
	got := filterRowsByTouched(rows, header, nil)
	if len(got) != 1 {
		t.Errorf("nil touched should pass through; got %d", len(got))
	}
}

func TestFilterRowsByTouched_NonClusterShape(t *testing.T) {
	// Pair and metric shapes pass through unchanged even when touched is set.
	for _, shape := range []string{"pair", "metric"} {
		shape := shape
		t.Run(shape, func(t *testing.T) {
			rows := []render.Row{{"cluster_id": "x", "shape": shape}}
			header := &frontmatter.Header{Shape: []string{shape}}
			got := filterRowsByTouched(rows, header, touchedSet{"some/path.ts": {}})
			if len(got) != 1 {
				t.Errorf("non-cluster shape should pass through; got %d", len(got))
			}
		})
	}
}

func TestFilterRowsByTouched_ClusterRow(t *testing.T) {
	touched := touchedSet{"src/foo.ts": {}, "src/bar.ts": {}}
	header := &frontmatter.Header{Shape: []string{"cluster"}}

	t.Run("kept when member.file matches touched", func(t *testing.T) {
		rows := []render.Row{clusterRow("c1", []map[string]any{{"file": "src/foo.ts"}})}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("want kept, got %d", len(got))
		}
	})

	t.Run("kept when member.touched_in_window true", func(t *testing.T) {
		rows := []render.Row{clusterRow("c2", []map[string]any{
			{"file": "elsewhere.ts", "touched_in_window": true},
		})}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("want kept, got %d", len(got))
		}
	})

	t.Run("dropped when no member touched and no file in set", func(t *testing.T) {
		rows := []render.Row{clusterRow("c3", []map[string]any{{"file": "elsewhere.ts"}})}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 0 {
			t.Errorf("want dropped, got %d", len(got))
		}
	})

	t.Run("file normalization matches across forms", func(t *testing.T) {
		// touched set normalized at load; member files normalized at compare.
		rows := []render.Row{clusterRow("c4", []map[string]any{{"file": "./src/foo.ts"}})}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("want kept (./ prefix should normalize), got %d", len(got))
		}
	})

	t.Run("empty touched set drops every cluster", func(t *testing.T) {
		rows := []render.Row{
			clusterRow("c5", []map[string]any{{"file": "src/foo.ts"}}),
			clusterRow("c6", []map[string]any{{"file": "src/bar.ts", "touched_in_window": false}}),
		}
		got := filterRowsByTouched(rows, header, touchedSet{})
		if len(got) != 0 {
			t.Errorf("empty touched should drop all; got %d", len(got))
		}
	})
}

func TestComposePRComment_EmptyResults(t *testing.T) {
	got := composePRComment(nil, prCommentOpts{marker: "test-marker", sizeCapBytes: 1000})
	if !strings.HasPrefix(got, "<!-- test-marker -->\n") {
		t.Errorf("output should start with marker; got first line: %q", firstLine(got))
	}
	if !strings.Contains(got, "No structural impact") {
		t.Errorf("empty results should produce no-impact body; got: %s", got)
	}
}

func TestComposePRComment_MarkerOnLine1(t *testing.T) {
	results := []sectionResult{
		{name: "q", header: &frontmatter.Header{Desc: "Q.", Shape: []string{"cluster"}}, blocks: []string{"### x\n\n- a\n"}},
	}
	got := composePRComment(results, prCommentOpts{marker: "code-audit-pipeline-v1", sizeCapBytes: 60000})
	first := firstLine(got)
	if first != "<!-- code-audit-pipeline-v1 -->" {
		t.Errorf("first line should be marker, got %q", first)
	}
}

func TestComposePRComment_DeterministicOrder(t *testing.T) {
	// Sections must render in alphabetical name order regardless of input order.
	mkSec := func(name string) sectionResult {
		return sectionResult{
			name:   name,
			header: &frontmatter.Header{Desc: "desc.", Shape: []string{"cluster"}},
			blocks: []string{"### " + name + "\n\n- a\n"},
		}
	}
	resultsAB := []sectionResult{mkSec("alpha"), mkSec("beta")}
	resultsBA := []sectionResult{mkSec("beta"), mkSec("alpha")}
	opts := prCommentOpts{marker: "m", sizeCapBytes: 60000}
	a := composePRComment(resultsAB, opts)
	b := composePRComment(resultsBA, opts)
	if a != b {
		t.Errorf("composePRComment is not deterministic across input order:\nA:\n%s\nB:\n%s", a, b)
	}
	// alpha should appear before beta in the body.
	ai := strings.Index(a, "## alpha")
	bi := strings.Index(a, "## beta")
	if ai < 0 || bi < 0 || ai >= bi {
		t.Errorf("alpha must precede beta in output; alpha=%d beta=%d", ai, bi)
	}
}

func TestComposePRComment_SizeCap_DropsWholeSection(t *testing.T) {
	mkSec := func(name string, blockSize int) sectionResult {
		body := strings.Repeat("x", blockSize)
		return sectionResult{
			name:   name,
			header: &frontmatter.Header{Desc: "desc.", Shape: []string{"cluster"}},
			blocks: []string{"### " + name + "\n\n- " + body + "\n"},
		}
	}
	// Cap = 200 bytes. Two ~150-byte sections: first fits, second blows the cap.
	results := []sectionResult{mkSec("alpha", 100), mkSec("beta", 100)}
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: 200})
	if !strings.Contains(got, "## alpha") {
		t.Errorf("alpha should be kept (fits under cap)")
	}
	if strings.Contains(got, "## beta") {
		t.Errorf("beta should be dropped (would exceed cap)")
	}
	if !strings.Contains(got, "1 more section(s) omitted") {
		t.Errorf("size-cap footer missing; got: %s", got)
	}
}

func TestComposePRComment_SizeCap_AllSectionsOversize(t *testing.T) {
	// Every section individually exceeds the cap.
	huge := strings.Repeat("x", 1000)
	results := []sectionResult{
		{name: "alpha", header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}}, blocks: []string{huge}},
		{name: "beta", header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}}, blocks: []string{huge}},
	}
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: 100})
	if !strings.Contains(got, "every report section exceeded") {
		t.Errorf("expected cap-overrun notice; got: %s", got)
	}
}

func TestComposePRComment_SkippedAndErroredSectionsExcluded(t *testing.T) {
	results := []sectionResult{
		{name: "good", header: &frontmatter.Header{Desc: "g.", Shape: []string{"cluster"}}, blocks: []string{"- a\n"}},
		{name: "skipped", skipped: "no rows"},
		{name: "errored", err: errStub("boom")},
	}
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: 60000})
	if !strings.Contains(got, "## good") {
		t.Errorf("good section missing")
	}
	if strings.Contains(got, "## skipped") || strings.Contains(got, "## errored") {
		t.Errorf("skipped/errored should be excluded from pr-comment body")
	}
	if strings.Contains(got, "Skipped queries") {
		t.Errorf("Skipped queries footer should not appear in pr-comment mode")
	}
}

func TestFailQuietBody(t *testing.T) {
	got := failQuietBody("m", []string{"typescript", "swift"})
	if !strings.HasPrefix(got, "<!-- m -->\n") {
		t.Errorf("missing marker prefix; got: %q", firstLine(got))
	}
	if !strings.Contains(got, "extraction failed for typescript, swift") {
		t.Errorf("languages not listed; got: %s", got)
	}

	gotEmpty := failQuietBody("m", nil)
	if !strings.Contains(gotEmpty, "<unknown>") {
		t.Errorf("empty languages should render <unknown>; got: %s", gotEmpty)
	}
}

// ---- helpers ----

func write(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func clusterRow(cid string, members []map[string]any) render.Row {
	memsAny := make([]any, 0, len(members))
	for _, m := range members {
		memsAny = append(memsAny, m)
	}
	return render.Row{
		"cluster_id": cid,
		"members":    memsAny,
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// errStub is a minimal error implementation for table-driven tests.
type errStub string

func (e errStub) Error() string { return string(e) }

// Sanity that touchedSet round-trips through JSON serialization in test fixtures.
func TestTouchedSet_RoundTrip(t *testing.T) {
	set := touchedSet{"a/b.ts": {}, "c/d.ts": {}}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	b, err := json.Marshal(keys)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "rt.json")
	write(t, path, string(b))
	got, err := loadTouchedSet(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(set) {
		t.Errorf("round-trip lost entries: have %d want %d", len(got), len(set))
	}
}
