package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/jakebromberg/code-audit-pipeline/internal/initstate"
)

// mkTree creates files described by layout under root. Each map key is a
// forward-slash relative path; an empty value creates a 0-byte file; a value
// ending in "/" creates an empty directory.
func mkTree(t *testing.T, root string, layout map[string]string) {
	t.Helper()
	for rel, body := range layout {
		full := filepath.Join(root, filepath.FromSlash(rel))
		if strings.HasSuffix(rel, "/") {
			if err := os.MkdirAll(full, 0o755); err != nil {
				t.Fatalf("mkdir %s: %v", full, err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir parent of %s: %v", full, err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", full, err)
		}
	}
}

// listFiles returns forward-slash relative paths of all regular files under
// dst, sorted.
func listFiles(t *testing.T, dst string) []string {
	t.Helper()
	var out []string
	err := fs.WalkDir(os.DirFS(dst), ".", func(rel string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if rel == "." || d.IsDir() {
			return nil
		}
		out = append(out, rel)
		return nil
	})
	if err != nil {
		t.Fatalf("walk dst: %v", err)
	}
	sort.Strings(out)
	return out
}

func TestRun_FlattenSkipsSubdirs(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{
		"top.jq":            "// top\n",
		"nested/inner.jq":   "// inner\n",
		"deep/a/b/leaf.jq":  "// leaf\n",
	})

	if _, err := Run(Options{Src: src, Dst: dst, Flatten: true, Ext: []string{".jq"}}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"top.jq"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("flatten: got %v, want %v", got, want)
	}
}

func TestRun_TreeModePreservesTree(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{
		"top.txt":          "a",
		"a/b/c.txt":        "c",
		"x/y.txt":          "y",
	})

	if _, err := Run(Options{Src: src, Dst: dst}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"a/b/c.txt", "top.txt", "x/y.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("tree: got %v, want %v", got, want)
	}
}

// genembed must skip dot-prefixed directories (.git, .idea, .vscode,
// .claude, etc.) at every depth so a contributor's IDE / worktree state
// does not bake into the embedded extractor tree shipped in the binary.
// Mirrors the rule in internal/cli/init.go's filesystem walker.
func TestRun_DotPrefixedDirsSkipped(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{
		"keep.txt":                "k",
		".git/HEAD":               "ref: refs/heads/main",
		".vscode/settings.json":   "{}",
		"extractors/ts/.idea/x":   "ide",
		"extractors/ts/src/y.mjs": "y",
	})

	if _, err := Run(Options{Src: src, Dst: dst}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"extractors/ts/src/y.mjs", "keep.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("dotdir skip: got %v, want %v", got, want)
	}
}

func TestRun_SkipPrunesAtEveryDepth(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{
		"top.txt":                                  "a",
		"node_modules/pkg/index.js":                "n",
		"extractors/ts/node_modules/dep/x.js":      "d",
		"extractors/ts/src/keep.mjs":               "k",
	})

	if _, err := Run(Options{Src: src, Dst: dst, Skip: map[string]bool{"node_modules": true}}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"extractors/ts/src/keep.mjs", "top.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("skip: got %v, want %v", got, want)
	}
}

func TestRun_ExtFilterFlatten(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{
		"a.jq":   "x",
		"b.md":   "y",
		"c.json": "z",
	})

	if _, err := Run(Options{Src: src, Dst: dst, Flatten: true, Ext: []string{".jq"}}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"a.jq"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ext filter: got %v, want %v", got, want)
	}
}

func TestRun_NoExtCopiesAll(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{
		"a.mjs":  "x",
		"b.toml": "y",
		"c.json": "z",
	})

	if _, err := Run(Options{Src: src, Dst: dst}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"a.mjs", "b.toml", "c.json"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("all ext: got %v, want %v", got, want)
	}
}

func TestRun_SymlinkToFileSkipped(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{"real.txt": "r"})
	if err := os.Symlink(filepath.Join(src, "real.txt"), filepath.Join(src, "link.txt")); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	if _, err := Run(Options{Src: src, Dst: dst}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"real.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("symlink file: got %v, want %v", got, want)
	}
}

func TestRun_SymlinkToDirSkipped(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	// Create a target tree outside src, then a symlink inside src pointing to it.
	outside := t.TempDir()
	mkTree(t, outside, map[string]string{"buried.txt": "b"})
	mkTree(t, src, map[string]string{"keep.txt": "k"})
	if err := os.Symlink(outside, filepath.Join(src, "linkdir")); err != nil {
		t.Fatalf("symlink dir: %v", err)
	}

	if _, err := Run(Options{Src: src, Dst: dst}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"keep.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("symlink dir: got %v, want %v", got, want)
	}
}

func TestRun_EmptyDirsNotCopied(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{
		"keep.txt":     "k",
		"empty/":       "",
		"a/empty-sub/": "",
		"a/b/c.txt":    "c",
	})

	if _, err := Run(Options{Src: src, Dst: dst}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	// Verify no directory under dst named "empty" exists.
	if _, err := os.Stat(filepath.Join(dst, "empty")); !os.IsNotExist(err) {
		t.Fatalf("empty/ should not be present at dst: stat err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "a", "empty-sub")); !os.IsNotExist(err) {
		t.Fatalf("a/empty-sub/ should not be present at dst: stat err = %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"a/b/c.txt", "keep.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("empty dirs: got %v, want %v", got, want)
	}
}

// A stale destination (from a previous generation) and a stale temp
// sibling (from a crashed run) must both be replaced: dst ends up exactly
// mirroring src, and the temp sibling is gone after a successful run.
func TestRun_ReplacesStaleDstAndRemovesTmpSibling(t *testing.T) {
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "out")
	mkTree(t, src, map[string]string{"fresh.txt": "f"})
	mkTree(t, dst, map[string]string{"stale.txt": "s"})
	mkTree(t, dst+".genembed-tmp", map[string]string{"crashed.txt": "c"})

	if _, err := Run(Options{Src: src, Dst: dst}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got := listFiles(t, dst)
	want := []string{"fresh.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("stale dst replace: got %v, want %v", got, want)
	}
	if _, err := os.Stat(dst + ".genembed-tmp"); !os.IsNotExist(err) {
		t.Fatalf("temp sibling should be removed after a successful run: stat err = %v", err)
	}
}

func TestRun_RefusesMissingSrc(t *testing.T) {
	dst := filepath.Join(t.TempDir(), "out")
	_, err := Run(Options{Src: "/definitely/does/not/exist/ohlordy", Dst: dst})
	if err == nil {
		t.Fatal("expected error for missing src, got nil")
	}
	if !strings.Contains(err.Error(), "missing") && !strings.Contains(err.Error(), "not a directory") {
		t.Fatalf("error should mention missing/not-a-dir: got %v", err)
	}
}

func TestRun_RefusesDstInsideSrc(t *testing.T) {
	src := t.TempDir()
	mkTree(t, src, map[string]string{"a.txt": "a"})

	_, err := Run(Options{Src: src, Dst: filepath.Join(src, "inside")})
	if err == nil {
		t.Fatal("expected error for dst inside src, got nil")
	}
	if !strings.Contains(err.Error(), "inside") {
		t.Fatalf("error should mention dst-inside-src: got %v", err)
	}
}

// TestSkipDrift_AgainstEmbedDirectives is the drift guard: every
// //go:generate line in cmd/code-audit/embed.go that invokes genembed AND
// passes -skip must use exactly the same set as initstate.SkipDirs.
//
// If a future genembed invocation needs a *different* skip set, factor
// SkipDirs into per-target maps and update this test to dispatch accordingly.
func TestSkipDrift_AgainstEmbedDirectives(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "cmd", "code-audit", "embed.go"))
	if err != nil {
		t.Fatalf("read embed.go: %v", err)
	}

	checked := 0
	for _, line := range strings.Split(string(data), "\n") {
		trim := strings.TrimSpace(line)
		if !strings.HasPrefix(trim, "//go:generate") {
			continue
		}
		if !strings.Contains(trim, "genembed") {
			continue
		}
		idx := strings.Index(trim, "-skip ")
		if idx == -1 {
			continue
		}
		tail := trim[idx+len("-skip "):]
		csvEnd := strings.IndexAny(tail, " \t")
		var csv string
		if csvEnd == -1 {
			csv = tail
		} else {
			csv = tail[:csvEnd]
		}

		got := map[string]bool{}
		for _, name := range strings.Split(csv, ",") {
			n := strings.TrimSpace(name)
			if n != "" {
				got[n] = true
			}
		}

		canonical := initstate.SkipDirs()
		if !reflect.DeepEqual(got, canonical) {
			t.Fatalf("//go:generate skip set %v does not match initstate.SkipDirs() %v",
				got, canonical)
		}
		checked++
	}

	if checked == 0 {
		t.Fatal("expected at least one //go:generate genembed line with -skip in cmd/code-audit/embed.go")
	}
}
