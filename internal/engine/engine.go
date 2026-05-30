// Package engine evaluates a jq query against a catalog input. Default
// engine is embedded gojq; queries that declare `#! engine: jq` shell out
// to system jq per ADR-0005.
package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/itchyny/gojq"
)

// Binding is a single --arg / --argjson value.
type Binding struct {
	Name    string
	IsJSON  bool // true → caller pre-parsed JSON in Value; false → string literal
	Value   any
}

// Slurpfile mounts a JSON file as a $NAME binding wrapped in a one-element
// array (jq slurpfile semantics).
type Slurpfile struct {
	Name string
	Path string
}

// Opts is everything one query invocation needs. Fields mirror jq's CLI:
//
//	QuerySource:  the .jq file body
//	LibDir:        -L <dir> (where _canonical.jq lives)
//	InputPath:     positional catalog file ("" means -n / null input)
//	Bindings:      --arg / --argjson
//	Slurpfiles:    --slurpfile NAME path
//	Env:           overlaid on the inherited environment; read via $ENV.NAME
//	Out:           destination for the iterator's emissions
//	Raw:           -r (strings emitted bare, non-strings JSON-encoded)
//	UseSystemJQ:   engine: jq shell-out; QueryFile is required when true
//	QueryFile:     absolute path on disk; required for system-jq path
type Opts struct {
	QuerySource string
	LibDir      string
	LibFS       fs.FS // embedded fallback when LibDir is ""
	InputPath   string
	Bindings    []Binding
	Slurpfiles  []Slurpfile
	Env         map[string]string
	Out         io.Writer
	Raw         bool
	UseSystemJQ bool
	QueryFile   string
}

// Run executes the query.
func Run(ctx context.Context, opts Opts) error {
	if opts.Out == nil {
		return errors.New("engine: Out is required")
	}
	if opts.UseSystemJQ {
		return runSystemJQ(ctx, opts)
	}
	return runGojq(ctx, opts)
}

func runGojq(ctx context.Context, opts Opts) error {
	query, err := gojq.Parse(opts.QuerySource)
	if err != nil {
		return fmt.Errorf("engine: parse query: %w", err)
	}

	// Collect variable names + values. gojq.WithVariables expects a fixed
	// slice; bindings + slurpfile vars are positional, matching the order
	// passed to code.Run.
	var varNames []string
	var varValues []any

	for _, b := range opts.Bindings {
		varNames = append(varNames, "$"+b.Name)
		varValues = append(varValues, b.Value)
	}
	for _, s := range opts.Slurpfiles {
		v, err := readSlurpfile(s.Path)
		if err != nil {
			return err
		}
		varNames = append(varNames, "$"+s.Name)
		varValues = append(varValues, v)
	}

	codeOpts := []gojq.CompilerOption{
		gojq.WithVariables(varNames),
		gojq.WithEnvironLoader(func() []string { return mergedEnviron(opts.Env) }),
	}
	if opts.LibDir != "" {
		codeOpts = append(codeOpts, gojq.WithModuleLoader(gojq.NewModuleLoader([]string{opts.LibDir})))
	} else if opts.LibFS != nil {
		codeOpts = append(codeOpts, gojq.WithModuleLoader(&fsLoader{fs: opts.LibFS}))
	}

	code, err := gojq.Compile(query, codeOpts...)
	if err != nil {
		return fmt.Errorf("engine: compile: %w", err)
	}

	var input any
	if opts.InputPath != "" {
		input, err = readJSON(opts.InputPath)
		if err != nil {
			return err
		}
	} else {
		input = nil
	}

	iter := code.RunWithContext(ctx, input, varValues...)
	for {
		v, ok := iter.Next()
		if !ok {
			return nil
		}
		if err, isErr := v.(error); isErr {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return err
			}
			return fmt.Errorf("engine: eval: %w", err)
		}
		if err := emit(opts.Out, v, opts.Raw); err != nil {
			return err
		}
	}
}

func emit(w io.Writer, v any, raw bool) error {
	if raw {
		if s, ok := v.(string); ok {
			_, err := io.WriteString(w, s+"\n")
			return err
		}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("engine: marshal output: %w", err)
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

func readJSON(path string) (any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("engine: read %s: %w", path, err)
	}
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, fmt.Errorf("engine: parse %s: %w", path, err)
	}
	return v, nil
}

func readSlurpfile(path string) (any, error) {
	v, err := readJSON(path)
	if err != nil {
		return nil, err
	}
	return []any{v}, nil
}

func mergedEnviron(extra map[string]string) []string {
	env := os.Environ()
	for k, v := range extra {
		env = append(env, k+"="+v)
	}
	return env
}

// fsLoader bridges an fs.FS-rooted library directory (the embedded queries)
// into gojq's ModuleLoader interface. gojq looks up include directives like
// `include "_canonical";` by name; the loader resolves to a path inside the
// fs.FS, reads the file, and parses it.
type fsLoader struct{ fs fs.FS }

func (l *fsLoader) LoadModule(name string) (*gojq.Query, error) {
	for _, candidate := range []string{name + ".jq", name} {
		data, err := fs.ReadFile(l.fs, candidate)
		if err == nil {
			return gojq.Parse(string(data))
		}
	}
	return nil, fmt.Errorf("engine: module %q not found in embedded FS", name)
}

// LoadInitModules satisfies the optional ModuleLoader extension; we have no
// always-loaded modules.
func (l *fsLoader) LoadInitModules() ([]*gojq.Query, error) { return nil, nil }

func runSystemJQ(ctx context.Context, opts Opts) error {
	if opts.QueryFile == "" {
		return errors.New("engine: system jq requires QueryFile")
	}
	libDir := opts.LibDir
	if libDir == "" && opts.LibFS != nil {
		// Embedded queries: materialize the library tree to a temp dir so jq
		// can resolve `include "_canonical";` via -L.
		dir, err := materializeLib(opts.LibFS)
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
		libDir = dir
	}
	args := []string{}
	if opts.Raw {
		args = append(args, "-r")
	}
	if opts.InputPath == "" {
		args = append(args, "-n")
	}
	if libDir != "" {
		args = append(args, "-L", libDir)
	}
	for _, b := range opts.Bindings {
		if b.IsJSON {
			raw, err := json.Marshal(b.Value)
			if err != nil {
				return fmt.Errorf("engine: argjson %s: %w", b.Name, err)
			}
			args = append(args, "--argjson", b.Name, string(raw))
		} else {
			s, _ := b.Value.(string)
			args = append(args, "--arg", b.Name, s)
		}
	}
	for _, s := range opts.Slurpfiles {
		args = append(args, "--slurpfile", s.Name, s.Path)
	}
	args = append(args, "-f", opts.QueryFile)
	if opts.InputPath != "" {
		args = append(args, opts.InputPath)
	}

	cmd := exec.CommandContext(ctx, "jq", args...)
	cmd.Env = mergedEnviron(opts.Env)
	cmd.Stdout = opts.Out
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("engine: jq subprocess: %w", err)
	}
	return nil
}

// materializeLib writes every regular file in libFS to a fresh temp directory
// so the system-jq subprocess can find them via -L. Caller is responsible for
// `os.RemoveAll(dir)`.
func materializeLib(libFS fs.FS) (string, error) {
	dir, err := os.MkdirTemp("", "audit-libjq-*")
	if err != nil {
		return "", fmt.Errorf("engine: tempdir for lib: %w", err)
	}
	err = fs.WalkDir(libFS, ".", func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		data, readErr := fs.ReadFile(libFS, path)
		if readErr != nil {
			return readErr
		}
		return os.WriteFile(filepath.Join(dir, path), data, 0o644)
	})
	if err != nil {
		os.RemoveAll(dir)
		return "", fmt.Errorf("engine: materialize lib: %w", err)
	}
	return dir, nil
}

