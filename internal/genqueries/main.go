// genqueries copies pipeline/queries/*.jq into cmd/code-audit/queries/ so the
// code-audit binary can embed them via //go:embed. Invoked by `go generate` in
// cmd/code-audit/embed.go. Refuses to operate if -src is missing or empty.
package main

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	src := flag.String("src", "", "source directory holding *.jq files")
	dst := flag.String("dst", "", "destination directory to populate")
	flag.Parse()

	if *src == "" || *dst == "" {
		log.Fatalf("genqueries: -src and -dst are required")
	}

	srcAbs, err := filepath.Abs(*src)
	if err != nil {
		log.Fatalf("genqueries: abs src: %v", err)
	}
	dstAbs, err := filepath.Abs(*dst)
	if err != nil {
		log.Fatalf("genqueries: abs dst: %v", err)
	}

	srcInfo, err := os.Stat(srcAbs)
	if err != nil || !srcInfo.IsDir() {
		log.Fatalf("genqueries: src %s missing or not a directory", srcAbs)
	}

	if err := os.RemoveAll(dstAbs); err != nil {
		log.Fatalf("genqueries: clear dst: %v", err)
	}
	if err := os.MkdirAll(dstAbs, 0o755); err != nil {
		log.Fatalf("genqueries: mkdir dst: %v", err)
	}

	copied := 0
	err = fs.WalkDir(os.DirFS(srcAbs), ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if !strings.HasSuffix(d.Name(), ".jq") {
			return nil
		}
		// Flatten: dst has no subdirectories beyond the queries themselves.
		// Subdirectories under pipeline/queries (e.g., _tests/) are skipped.
		if strings.Contains(path, "/") {
			return nil
		}
		in, err := os.Open(filepath.Join(srcAbs, path))
		if err != nil {
			return err
		}
		defer in.Close()
		outPath := filepath.Join(dstAbs, d.Name())
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
	if err != nil {
		log.Fatalf("genqueries: walk: %v", err)
	}
	if copied == 0 {
		log.Fatalf("genqueries: no .jq files copied from %s", srcAbs)
	}
	fmt.Fprintf(os.Stderr, "genqueries: copied %d files to %s\n", copied, dstAbs)
}
