package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/discovery"
	"github.com/jakebromberg/code-audit-pipeline/internal/engine"
	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
)

// slurpfileVar maps a catalog kind to the gojq variable name when mounted as
// a slurpfile. Mirrors the convention real queries use (see plan PR 3
// "Catalog declarations").
var slurpfileVar = map[string]string{
	"type-catalog":     "types",
	"function-catalog": "functions",
	"references-graph": "refs",
	"files":            "files",
	"file-hashes":      "hashes",
}

// Query implements `audit query <name> ...`.
func Query(ctx context.Context, argv []string, stdout io.Writer, queriesFS fs.FS) int {
	if len(argv) < 1 {
		fmt.Fprintln(stdout, "usage: audit query <name> [flags]")
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
		fmt.Fprintf(stdout, "audit: --format must be text or jsonl, got %q\n", *format)
		return 2
	}

	root := *rootFlag
	if root == "" {
		cwd, _ := os.Getwd()
		root = cwd
	}
	absRoot, _ := filepath.Abs(root)

	// Resolve the query file.
	qsrc, err := discovery.ResolveQueriesDir(discovery.QueryOpts{
		Flag: *queriesDir, AuditHome: os.Getenv("AUDIT_HOME"), CWD: absRoot,
	}, queriesFS)
	if err != nil {
		fmt.Fprintf(stdout, "audit: %v\n", err)
		return 3
	}
	queryBody, queryFile, cleanup, err := readQuery(qsrc, name)
	if err != nil {
		fmt.Fprintf(stdout, "audit: %v\n", err)
		return 3
	}
	defer cleanup()
	header, err := frontmatter.Parse(strings.NewReader(queryBody))
	if err != nil {
		fmt.Fprintf(stdout, "audit: front-matter %s: %v\n", name, err)
		return 2
	}
	if !supportsFormat(header.Formats, *format) {
		fmt.Fprintf(stdout, "audit: query %s does not support format %q (supports: %s)\n",
			name, *format, strings.Join(header.Formats, ", "))
		return 2
	}

	// Build bindings + validate against front-matter args.
	bindings, err := buildBindings(header, argFlags, argJSONFlags)
	if err != nil {
		fmt.Fprintf(stdout, "audit: %v\n", err)
		return 2
	}

	// Wire catalog inputs.
	inputPath, slurpfiles, err := wireCatalogs(absRoot, header, catalogPaths)
	if err != nil {
		fmt.Fprintf(stdout, "audit: %v\n", err)
		return 3
	}

	// Env overlay: front-matter defaults first, then --env overrides, then
	// OUTPUT_FORMAT from --format.
	env := map[string]string{}
	for _, e := range header.Envs {
		env[e.Name] = e.Default
	}
	for _, kv := range envFlags {
		k, v, ok := splitKV(kv)
		if !ok {
			fmt.Fprintf(stdout, "audit: --env expects NAME=VALUE, got %q\n", kv)
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
		fmt.Fprintf(stdout, "audit: query %s: %v\n", name, err)
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
		// Materialize to a temp file so the system-jq fallback path has a path
		// to point at via -f. The caller cleans up via the returned func.
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

func supportsFormat(declared []string, want string) bool {
	for _, f := range declared {
		if f == want {
			return true
		}
	}
	return false
}

func buildBindings(h *frontmatter.Header, args, argjsons stringList) ([]engine.Binding, error) {
	given := map[string]engine.Binding{}
	for _, kv := range args {
		k, v, ok := splitKV(kv)
		if !ok {
			return nil, fmt.Errorf("--arg expects NAME=VALUE, got %q", kv)
		}
		given[k] = engine.Binding{Name: k, IsJSON: false, Value: v}
	}
	for _, kv := range argjsons {
		k, v, ok := splitKV(kv)
		if !ok {
			return nil, fmt.Errorf("--argjson expects NAME=JSON, got %q", kv)
		}
		var parsed any
		if err := json.Unmarshal([]byte(v), &parsed); err != nil {
			return nil, fmt.Errorf("--argjson %s: %w", k, err)
		}
		given[k] = engine.Binding{Name: k, IsJSON: true, Value: parsed}
	}

	out := make([]engine.Binding, 0, len(h.Args))
	for _, decl := range h.Args {
		b, ok := given[decl.Name]
		if !ok {
			if decl.Required {
				return nil, fmt.Errorf("query requires --arg %s (or --argjson)", decl.Name)
			}
			b = engine.Binding{Name: decl.Name, IsJSON: decl.Type != "string", Value: parseDefault(decl.Type, decl.Default)}
		}
		if err := typecheckBinding(decl, b); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	// Reject undeclared bindings.
	for k := range given {
		if !hasArg(h.Args, k) {
			return nil, fmt.Errorf("query does not declare --arg %s (declared: %s)", k, declaredArgNames(h.Args))
		}
	}
	return out, nil
}

func hasArg(args []frontmatter.ArgDecl, name string) bool {
	for _, a := range args {
		if a.Name == name {
			return true
		}
	}
	return false
}

func declaredArgNames(args []frontmatter.ArgDecl) string {
	names := make([]string, len(args))
	for i, a := range args {
		names[i] = a.Name
	}
	if len(names) == 0 {
		return "(none)"
	}
	return strings.Join(names, ", ")
}

func parseDefault(typ, def string) any {
	if def == "" {
		return ""
	}
	switch typ {
	case "number":
		f, err := strconv.ParseFloat(def, 64)
		if err == nil {
			return f
		}
	case "json":
		var v any
		if err := json.Unmarshal([]byte(def), &v); err == nil {
			return v
		}
	}
	return def
}

func typecheckBinding(decl frontmatter.ArgDecl, b engine.Binding) error {
	switch decl.Type {
	case "number":
		if !b.IsJSON {
			// --arg form passes a string; gojq will compare against numbers awkwardly.
			// Allow but reject obvious non-numerics.
			s, _ := b.Value.(string)
			if _, err := strconv.ParseFloat(s, 64); err != nil {
				return fmt.Errorf("arg %s declared number, got %q", decl.Name, s)
			}
		}
	case "string":
		// any value coerces to string in jq; accept silently.
	case "json":
		if !b.IsJSON {
			return fmt.Errorf("arg %s declared json, requires --argjson", decl.Name)
		}
	}
	return nil
}

func wireCatalogs(absRoot string, h *frontmatter.Header, overrides stringList) (string, []engine.Slurpfile, error) {
	declared := h.Catalog
	if len(overrides) > 0 && len(overrides) != len(declared) {
		return "", nil, fmt.Errorf("--catalog given %d times but query declares %d catalog inputs", len(overrides), len(declared))
	}

	// Special case: two-of-same-kind (cross-catalog-name-collisions).
	twoSame := len(declared) == 2 && declared[0] == declared[1]
	if twoSame {
		if len(overrides) != 2 {
			return "", nil, errors.New("two-of-same-kind catalog query requires two --catalog overrides")
		}
		return "", []engine.Slurpfile{
			{Name: "left", Path: overrides[0]},
			{Name: "right", Path: overrides[1]},
		}, nil
	}

	// Default: first declared is positional, trailing are slurpfiles.
	resolvePath := func(idx int, kind string) (string, error) {
		if idx < len(overrides) {
			return overrides[idx], nil
		}
		// Read from .audit/ cache.
		cache, err := auditdir.Open(absRoot, Version)
		if err != nil {
			return "", err
		}
		p, ok := cache.CatalogPath(kind)
		if !ok {
			return "", fmt.Errorf("catalog %q not cached under .audit/ — run `audit extract` or pass --catalog <path>", kind)
		}
		return p, nil
	}

	positional, err := resolvePath(0, declared[0])
	if err != nil {
		return "", nil, err
	}
	var slurpfiles []engine.Slurpfile
	for i := 1; i < len(declared); i++ {
		p, err := resolvePath(i, declared[i])
		if err != nil {
			return "", nil, err
		}
		vname, ok := slurpfileVar[declared[i]]
		if !ok {
			return "", nil, fmt.Errorf("no slurpfile variable mapping for catalog kind %q", declared[i])
		}
		slurpfiles = append(slurpfiles, engine.Slurpfile{Name: vname, Path: p})
	}
	return positional, slurpfiles, nil
}

func splitKV(s string) (string, string, bool) {
	eq := strings.IndexByte(s, '=')
	if eq < 1 {
		return "", "", false
	}
	return s[:eq], s[eq+1:], true
}
