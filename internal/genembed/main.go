// genembed copies source trees into a destination directory so the
// code-audit binary can embed them via //go:embed. Invoked by `go generate`
// directives in cmd/code-audit/embed.go (once per embedded tree). Default
// mode preserves the source tree; `-flatten` collapses it to top-level files
// only (the historical behaviour used for pipeline/queries).
package main

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// Options is the testable surface for the generator. main() parses flags
// into Options and calls Run.
type Options struct {
	Src     string
	Dst     string
	Flatten bool            // when true, only top-level files in Src are copied
	Ext     []string        // file extensions to include (with leading "."); empty = all
	Skip    map[string]bool // directory basenames to prune at every depth
}

func main() {
	src := flag.String("src", "", "source directory")
	dst := flag.String("dst", "", "destination directory")
	flatten := flag.Bool("flatten", false, "only copy top-level files in src (no subdirs)")
	extCSV := flag.String("ext", "", `comma-separated extension filter (e.g. ".jq,.go"); empty means all`)
	skipCSV := flag.String("skip", "", "comma-separated directory basenames to prune at every depth")
	flag.Parse()

	if *src == "" || *dst == "" {
		log.Fatalf("genembed: -src and -dst are required")
	}

	opts := Options{
		Src:     *src,
		Dst:     *dst,
		Flatten: *flatten,
		Ext:     parseCSV(*extCSV),
		Skip:    parseSet(*skipCSV),
	}
	copied, err := Run(opts)
	if err != nil {
		log.Fatalf("genembed: %v", err)
	}
	if copied == 0 {
		log.Fatalf("genembed: no files copied from %s", opts.Src)
	}
	fmt.Fprintf(os.Stderr, "genembed: copied %d files to %s\n", copied, opts.Dst)
}

func parseCSV(s string) []string {
	if s == "" {
		return nil
	}
	var out []string
	for _, t := range strings.Split(s, ",") {
		t = strings.TrimSpace(t)
		if t != "" {
			out = append(out, t)
		}
	}
	return out
}

func parseSet(s string) map[string]bool {
	if s == "" {
		return nil
	}
	out := map[string]bool{}
	for _, t := range strings.Split(s, ",") {
		t = strings.TrimSpace(t)
		if t != "" {
			out[t] = true
		}
	}
	return out
}

// Run walks opts.Src and copies matching regular files into opts.Dst. dst is
// fully cleared before the walk. Symlinks (file or directory) are not
// followed. Empty source directories are not preserved.
func Run(opts Options) (int, error) {
	srcAbs, err := filepath.Abs(opts.Src)
	if err != nil {
		return 0, fmt.Errorf("abs src: %w", err)
	}
	dstAbs, err := filepath.Abs(opts.Dst)
	if err != nil {
		return 0, fmt.Errorf("abs dst: %w", err)
	}

	srcInfo, err := os.Stat(srcAbs)
	if err != nil || !srcInfo.IsDir() {
		return 0, fmt.Errorf("src %s missing or not a directory", srcAbs)
	}

	if dstAbs == srcAbs || strings.HasPrefix(dstAbs, srcAbs+string(os.PathSeparator)) {
		return 0, fmt.Errorf("dst %s resolves inside src %s", dstAbs, srcAbs)
	}

	if err := os.RemoveAll(dstAbs); err != nil {
		return 0, fmt.Errorf("clear dst: %w", err)
	}
	if err := os.MkdirAll(dstAbs, 0o755); err != nil {
		return 0, fmt.Errorf("mkdir dst: %w", err)
	}

	copied := 0
	walkErr := fs.WalkDir(os.DirFS(srcAbs), ".", func(rel string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}

		base := path.Base(rel)

		if d.IsDir() {
			// Skip-by-basename (from --skip CSV) plus dot-prefixed
			// directories at any depth (.git, .idea, .vscode, .claude,
			// .next, .cursor, etc.). The init.go walker applies the same
			// rule for filesystem --from copies; without this clause the
			// embedded extractor tree could bake IDE state into the
			// shipped binary.
			if opts.Skip[base] || strings.HasPrefix(base, ".") {
				return fs.SkipDir
			}
			return nil
		}

		// fs.WalkDir does not recurse into symlinked directories, but it does
		// visit symlinks to files. Drop both so a hostile symlink under src
		// has no observable effect on dst.
		if d.Type()&os.ModeSymlink != 0 {
			return nil
		}

		if opts.Flatten && strings.Contains(rel, "/") {
			return nil
		}

		if len(opts.Ext) > 0 {
			ext := filepath.Ext(rel)
			matched := false
			for _, want := range opts.Ext {
				if ext == want {
					matched = true
					break
				}
			}
			if !matched {
				return nil
			}
		}

		var outPath string
		if opts.Flatten {
			outPath = filepath.Join(dstAbs, base)
		} else {
			outPath = filepath.Join(dstAbs, filepath.FromSlash(rel))
			if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
				return fmt.Errorf("mkdir intermediate: %w", err)
			}
		}

		in, err := os.Open(filepath.Join(srcAbs, filepath.FromSlash(rel)))
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.Create(outPath)
		if err != nil {
			return err
		}
		defer out.Close()
		if _, err := io.Copy(out, in); err != nil {
			return err
		}
		copied++
		return nil
	})
	if walkErr != nil {
		return copied, fmt.Errorf("walk: %w", walkErr)
	}
	return copied, nil
}
