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

	t.Run("JSON null is rejected loud (not silently empty)", func(t *testing.T) {
		path := filepath.Join(dir, "null.json")
		write(t, path, `null`)
		_, err := loadTouchedSet(path)
		if err == nil {
			t.Fatal("want error for JSON null top-level — silent empty-set fallback would mask a misconfigured resolve-touched.sh")
		}
		if !strings.Contains(err.Error(), "JSON null") {
			t.Errorf("error should name JSON null specifically; got: %v", err)
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

func TestFilterRowsByTouched_PerRowShape(t *testing.T) {
	// Per-row shape dispatch handles dual-shape queries that emit rows of
	// multiple shapes in a single stream (e.g. function-duplicates.jq's
	// cluster + pair sections).
	touched := touchedSet{"src/foo.ts": {}}
	header := &frontmatter.Header{Shape: []string{"cluster", "pair"}}

	t.Run("cluster row matched via member.file", func(t *testing.T) {
		rows := []render.Row{
			{"cluster_id": "c1", "shape": "cluster", "members": []any{
				map[string]any{"file": "src/foo.ts"},
			}},
		}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("cluster row with matching member should be kept; got %d", len(got))
		}
	})

	t.Run("pair row matched via left.file", func(t *testing.T) {
		rows := []render.Row{
			{"cluster_id": "p1", "shape": "pair",
				"left":  map[string]any{"file": "src/foo.ts"},
				"right": map[string]any{"file": "elsewhere.ts"},
			},
		}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("pair row with left.file in touched should be kept; got %d", len(got))
		}
	})

	t.Run("pair row matched via right.file", func(t *testing.T) {
		rows := []render.Row{
			{"cluster_id": "p2", "shape": "pair",
				"left":  map[string]any{"file": "elsewhere.ts"},
				"right": map[string]any{"file": "src/foo.ts"},
			},
		}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("pair row with right.file in touched should be kept; got %d", len(got))
		}
	})

	t.Run("pair row dropped when neither endpoint touched", func(t *testing.T) {
		rows := []render.Row{
			{"cluster_id": "p3", "shape": "pair",
				"left":  map[string]any{"file": "a.ts"},
				"right": map[string]any{"file": "b.ts"},
			},
		}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 0 {
			t.Errorf("untouched pair row should be dropped; got %d", len(got))
		}
	})

	t.Run("pair row matched via left.touched_in_window", func(t *testing.T) {
		rows := []render.Row{
			{"cluster_id": "p4", "shape": "pair",
				"left":  map[string]any{"file": "a.ts", "touched_in_window": true},
				"right": map[string]any{"file": "b.ts"},
			},
		}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("pair row with touched_in_window endpoint should be kept; got %d", len(got))
		}
	})

	t.Run("metric rows always kept (self-filtering payload)", func(t *testing.T) {
		rows := []render.Row{{"cluster_id": "m1", "shape": "metric"}}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("metric row should be kept (query self-filters); got %d", len(got))
		}
	})

	t.Run("envelope-level touched_in_window short-circuits regardless of shape", func(t *testing.T) {
		rows := []render.Row{
			{"cluster_id": "e1", "shape": "cluster", "touched_in_window": true, "members": []any{
				map[string]any{"file": "completely-other.ts"},
			}},
		}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("envelope-level touched_in_window should keep the row; got %d", len(got))
		}
	})

	t.Run("unknown shape conservatively dropped", func(t *testing.T) {
		rows := []render.Row{{"cluster_id": "u1", "shape": "novel-shape"}}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 0 {
			t.Errorf("unknown shape should be dropped; got %d", len(got))
		}
	})
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

	t.Run("kept when member.path matches touched (cross-package-backward-imports.jq)", func(t *testing.T) {
		// Regression: cross-package-backward-imports.jq emits members with
		// `path:` (sourced from files.json) rather than `file:`. The
		// touched-filter must check both keys, otherwise this query's
		// clusters silently never surface in PR comments.
		rows := []render.Row{clusterRow("cpbi", []map[string]any{
			{"path": "src/foo.ts", "package": "shared"},
		})}
		got := filterRowsByTouched(rows, header, touched)
		if len(got) != 1 {
			t.Errorf("want kept (members with `path` not `file` must also match touched); got %d", len(got))
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
	// Cap = 500 (covers header + alpha ~150 bytes + footer reserve 250). beta
	// would push past effective budget (500 - 250 footer - ~35 header = 215).
	results := []sectionResult{mkSec("alpha", 100), mkSec("beta", 100)}
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: 500})
	if !strings.Contains(got, "## alpha") {
		t.Errorf("alpha should be kept (fits under cap); got: %s", got)
	}
	if strings.Contains(got, "## beta") {
		t.Errorf("beta should be dropped (would exceed cap); got: %s", got)
	}
	if !strings.Contains(got, "section(s) omitted") {
		t.Errorf("size-cap footer missing; got: %s", got)
	}
	// New: footer should name the omitted section so the PR reader can find it.
	if !strings.Contains(got, "beta") {
		t.Errorf("footer should name dropped section 'beta'; got: %s", got)
	}
}

func TestComposePRComment_SizeCap_AlphabeticalPrefixPreserved(t *testing.T) {
	// When alpha overflows, ALL later sections must be dropped (not just
	// alpha). Otherwise a smaller beta could sneak past alpha, breaking
	// the alphabetical-prefix invariant.
	mkSec := func(name string, n int) sectionResult {
		return sectionResult{
			name:   name,
			header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}},
			blocks: []string{"### " + name + "\n\n- " + strings.Repeat("x", n) + "\n"},
		}
	}
	// alpha is too big; beta is tiny. Without prefix preservation, beta
	// would be kept while alpha is dropped — non-obvious to readers.
	results := []sectionResult{mkSec("alpha", 1000), mkSec("beta", 10)}
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: 500})
	if strings.Contains(got, "## alpha") {
		t.Errorf("alpha should be dropped (too large)")
	}
	if strings.Contains(got, "## beta") {
		t.Errorf("beta should also be dropped (prefix preservation); got: %s", got)
	}
}

func TestComposePRComment_SizeCap_AllSectionsOversize(t *testing.T) {
	// Every section individually exceeds the effective cap. The cap-overrun
	// fallback should name the omitted sections (so the PR author can find
	// them in the workflow logs) AND stay under capBytes.
	huge := strings.Repeat("x", 1000)
	results := []sectionResult{
		{name: "alpha", header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}}, blocks: []string{huge}},
		{name: "beta", header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}}, blocks: []string{huge}},
	}
	cap := 500
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: cap})
	if !strings.Contains(got, "section(s) omitted") {
		t.Errorf("expected truncation footer (kept==0 path should still list omitted sections); got: %s", got)
	}
	if !strings.Contains(got, "alpha") || !strings.Contains(got, "beta") {
		t.Errorf("footer should name omitted sections 'alpha' and 'beta'; got: %s", got)
	}
	if len(got) > cap {
		t.Errorf("body length %d exceeds cap %d (pathological branch overruns cap):\n%s", len(got), cap, got)
	}
}

func TestComposePRComment_SizeCap_RealisticQueryNames(t *testing.T) {
	// Regression: prior footerReserve=250 was undersized for realistic
	// query-name lengths. Use the longest in-tree query names to assert
	// the footer envelope is sized correctly.
	longNames := []string{
		"cross-package-shape-near-duplicates-any",
		"cross-package-shape-near-duplicates",
		"cross-catalog-name-collisions",
		"protocol-inheritance-candidates",
		"cross-package-backward-imports",
		"touched-window-debt-summary",
		"function-duplicates",
		"versioned-type-pairs",
	}
	results := make([]sectionResult, len(longNames))
	for i, n := range longNames {
		results[i] = sectionResult{
			name:   n,
			header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}},
			blocks: []string{"### " + n + "\n\n- " + strings.Repeat("x", 500) + "\n"},
		}
	}
	cap := 1000
	got := composePRComment(results, prCommentOpts{marker: "code-audit-pipeline-v1", sizeCapBytes: cap})
	if len(got) > cap {
		t.Errorf("body length %d exceeds cap %d with realistic query names:\n%s", len(got), cap, got)
	}
}

func TestComposePRComment_SizeCap_LargeMarkerRejectedAtFlagBoundary(t *testing.T) {
	// validateMarker enforces a 128-byte ceiling so a pathologically long
	// marker can't blow the header past any sensible cap. This test
	// pins the contract — composePRComment trusts its input.
	bigMarker := strings.Repeat("a", 200)
	if validateMarker(bigMarker) {
		t.Errorf("validateMarker should reject markers over %d chars; got accepted", markerMaxLen)
	}
}

func TestComposePRComment_SizeCap_FinalBodyStaysUnderCap(t *testing.T) {
	// Regression: the truncation footer used to be appended without
	// accounting against the cap, so a body could end up cap+footer-size.
	// Now the cap math reserves a footer envelope so the total stays under.
	mkSec := func(name string, n int) sectionResult {
		return sectionResult{
			name:   name,
			header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}},
			blocks: []string{"### " + name + "\n\n- " + strings.Repeat("x", n) + "\n"},
		}
	}
	results := []sectionResult{
		mkSec("alpha", 100),
		mkSec("beta", 100),
		mkSec("gamma", 100),
		mkSec("delta", 100),
	}
	cap := 500
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: cap})
	if len(got) > cap {
		t.Errorf("body length %d exceeds cap %d (truncation footer overflow)", len(got), cap)
	}
}

func TestComposePRComment_DoesNotMutateInput(t *testing.T) {
	// Regression: composePRComment used to sort the caller's slice in place.
	mkSec := func(name string) sectionResult {
		return sectionResult{
			name:   name,
			header: &frontmatter.Header{Desc: "d.", Shape: []string{"cluster"}},
			blocks: []string{"- a\n"},
		}
	}
	results := []sectionResult{mkSec("beta"), mkSec("alpha")}
	before := []string{results[0].name, results[1].name}
	_ = composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: 60000})
	after := []string{results[0].name, results[1].name}
	if before[0] != after[0] || before[1] != after[1] {
		t.Errorf("composePRComment mutated caller's slice: before=%v after=%v", before, after)
	}
}

func TestComposePRComment_NilHeaderDoesNotPanic(t *testing.T) {
	// Defensive: a sectionResult with blocks but nil header should be
	// skipped rather than crash on r.header.Desc dereference.
	results := []sectionResult{
		{name: "ok", header: &frontmatter.Header{Desc: "Q.", Shape: []string{"cluster"}}, blocks: []string{"- a\n"}},
		{name: "bad", header: nil, blocks: []string{"- b\n"}},
	}
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("composePRComment panicked on nil header: %v", r)
		}
	}()
	got := composePRComment(results, prCommentOpts{marker: "m", sizeCapBytes: 60000})
	if !strings.Contains(got, "## ok") {
		t.Errorf("ok section should still render despite bad sibling")
	}
}

func TestValidateMarker(t *testing.T) {
	good := []string{
		"code-audit-pipeline-v1",
		"foo",
		"a/b/c",
		"v1.2.3",
		"ns:marker",
		"a_underscore", // starts with alphanum
	}
	bad := []string{
		"",
		"has space",
		"foo-->",
		"foo<bar>",
		"line\nbreak",
		"with&amp;",
		"with\rcarriage",
		"with-->in-middle",
		"emoji😀",
		"-leading-dash",       // leading non-alphanumeric
		"_underscore",         // starts with underscore (not alphanum)
		"/leading-slash",      // leading slash
		"foo--bar",            // adjacent --
		strings.Repeat("a", 129), // exceeds length limit
		"\ttab",
	}
	for _, s := range good {
		if !validateMarker(s) {
			t.Errorf("validateMarker(%q) = false, want true", s)
		}
	}
	for _, s := range bad {
		if validateMarker(s) {
			t.Errorf("validateMarker(%q) = true, want false", s)
		}
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
	got := failQuietBody("m", []string{"typescript", "swift"}, 60000)
	if !strings.HasPrefix(got, "<!-- m -->\n") {
		t.Errorf("missing marker prefix; got: %q", firstLine(got))
	}
	if !strings.Contains(got, "extraction failed for typescript, swift") {
		t.Errorf("languages not listed; got: %s", got)
	}

	gotEmpty := failQuietBody("m", nil, 60000)
	if !strings.Contains(gotEmpty, "<unknown>") {
		t.Errorf("empty languages should render <unknown>; got: %s", gotEmpty)
	}
}

func TestFailQuietBody_RespectsCap(t *testing.T) {
	// A small cap with many languages should truncate the language list
	// with a "(+N more)" suffix and keep the body under capBytes.
	langs := []string{"typescript", "swift", "go", "python", "rust", "kotlin", "java", "csharp"}
	cap := 120
	got := failQuietBody("m", langs, cap)
	if len(got) > cap {
		t.Errorf("body length %d exceeds cap %d for many-languages truncation:\n%s", len(got), cap, got)
	}
	if !strings.Contains(got, "more") {
		t.Errorf("expected '(+N more)' suffix when languages were truncated; got: %s", got)
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
