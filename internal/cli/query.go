package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
	"github.com/jakebromberg/code-audit-pipeline/internal/engine"
	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
)

// Query implements `code-audit query <name> ...`.
func Query(ctx context.Context, argv []string, stdout io.Writer, queriesFS fs.FS) int {
	if len(argv) < 1 {
		fmt.Fprintln(stdout, "usage: code-audit query <name> [flags]")
		return 2
	}
	name := argv[0]
	fset := flag.NewFlagSet("query", flag.ContinueOnError)
	rootFlag := fset.String("root", "", "audit root (defaults to cwd)")
	queriesDir := fset.String("queries-dir", "", "explicit queries directory")
	format := fset.String("format", "text", "output format: text or jsonl")
	var argFlags, argJSONFlags, envFlags, catalogPaths stringList
	fset.Var(&argFlags, "arg", "--arg NAME=VALUE (repeatable)")
	fset.Var(&argJSONFlags, "argjson", "--argjson NAME=JSON (repeatable)")
	fset.Var(&envFlags, "env", "--env NAME=VALUE (repeatable)")
	fset.Var(&catalogPaths, "catalog", "explicit catalog path override; pass once per front-matter catalog entry, in order")
	if err := fset.Parse(argv[1:]); err != nil {
		return 2
	}
	if *format != "text" && *format != "jsonl" {
		fmt.Fprintf(stdout, "code-audit: --format must be text or jsonl, got %q\n", *format)
		return 2
	}

	root := *rootFlag
	if root == "" {
		cwd, _ := os.Getwd()
		root = cwd
	}
	absRoot, _ := filepath.Abs(root)

	qsrc, err := discovery.ResolveQueriesDir(discovery.QueryOpts{
		Flag: *queriesDir, AuditHome: os.Getenv("AUDIT_HOME"), CWD: absRoot,
	}, queriesFS)
	if err != nil {
		fmt.Fprintf(stdout, "code-audit: %v\n", err)
		return 3
	}
	queryBody, queryFile, cleanup, err := readQuery(qsrc, name)
	if err != nil {
		fmt.Fprintf(stdout, "code-audit: %v\n", err)
		return 3
	}
	defer cleanup()
	header, err := frontmatter.Parse(strings.NewReader(queryBody))
	if err != nil {
		fmt.Fprintf(stdout, "code-audit: front-matter %s: %v\n", name, err)
		return 2
	}
	if !supportsFormat(header.Formats, *format) {
		fmt.Fprintf(stdout, "code-audit: query %s does not support format %q (supports: %s)\n",
			name, *format, strings.Join(header.Formats, ", "))
		return 2
	}

	bindings, err := buildBindings(header, argFlags, argJSONFlags)
	if err != nil {
		fmt.Fprintf(stdout, "code-audit: %v\n", err)
		return 2
	}

	inputPath, slurpfiles, err := wireCatalogs(absRoot, header, catalogPaths)
	if err != nil {
		fmt.Fprintf(stdout, "code-audit: %v\n", err)
		return 3
	}

	env := map[string]string{}
	for _, e := range header.Envs {
		env[e.Name] = e.Default
	}
	for _, kv := range envFlags {
		k, v, ok := splitKV(kv)
		if !ok {
			fmt.Fprintf(stdout, "code-audit: --env expects NAME=VALUE, got %q\n", kv)
			return 2
		}
		env[k] = v
	}
	env["OUTPUT_FORMAT"] = *format

	opts := engine.Opts{
		QuerySource: queryBody,
		InputPath:   inputPath,
		Bindings:    bindings,
		Slurpfiles:  slurpfiles,
		Env:         env,
		Out:         stdout,
		Raw:         true,
		UseSystemJQ: header.Engine == "jq",
		QueryFile:   queryFile,
	}
	if qsrc.Path != "" {
		opts.LibDir = qsrc.Path
	} else {
		opts.LibFS = qsrc.FS
	}

	if err := engine.Run(ctx, opts); err != nil {
		fmt.Fprintf(stdout, "code-audit: query %s: %v\n", name, err)
		return 1
	}
	return 0
}

// readQuery returns the query source, an on-disk path to it (for the
// system-jq -f fallback), and a cleanup func the caller must defer. The
// cleanup removes any temp files created for embedded-FS queries; it is a
// no-op when the query already lives on disk.
func readQuery(src discovery.Source, name string) (string, string, func(), error) {
	filename := name + ".jq"
	noop := func() {}
	if src.FS != nil {
		data, err := fs.ReadFile(src.FS, filename)
		if err != nil {
			return "", "", noop, fmt.Errorf("read embedded query %s: %w", name, err)
		}
		tmp, err := os.CreateTemp("", "audit-query-*.jq")
		if err != nil {
			return "", "", noop, fmt.Errorf("tempfile: %w", err)
		}
		if _, err := tmp.Write(data); err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
			return "", "", noop, fmt.Errorf("write tempfile: %w", err)
		}
		tmp.Close()
		path := tmp.Name()
		cleanup := func() { os.Remove(path) }
		return string(data), path, cleanup, nil
	}
	p := filepath.Join(src.Path, filename)
	data, err := os.ReadFile(p)
	if err != nil {
		return "", "", noop, fmt.Errorf("read query %s: %w", p, err)
	}
	return string(data), p, noop, nil
}
