// Package extractor implements subprocess invocation of an extractor per its
// manifest.toml [[command]] block. Placeholder substitution and optional_args
// activation follow the grammar documented in extractors/*/manifest.toml.
package extractor

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/jakebromberg/code-audit-pipeline/internal/manifest"
)

// Args bundles the user-supplied inputs that drive placeholder substitution.
type Args struct {
	Root           string
	Shared         string
	Touched        string
	IncludeTests   bool
	MinBodyLines   int    // >0 to activate; 0 means "not set"
	Extensions     string // comma-separated
	EmitReferences bool
	EmitFiles      bool
}

// Result records what the runner produced. CLIArgs is the subset of Args that
// were actually consumed by this command (for `.audit/meta.json.catalogs[].cli_args`).
type Result struct {
	Catalog    string
	OutputPath string // absolute
	CLIArgs    map[string]any
}

// Run executes one [[command]] block. extractorDir is the absolute path that
// contains the extractor scripts (cwd for the subprocess). catalogsDir is the
// absolute path where output files land (typically .audit/catalogs/).
//
// Returns one Result for the primary catalog plus one per activated
// sibling_output.
func Run(ctx context.Context, extractorDir string, cmd manifest.Command, args Args, catalogsDir string) ([]Result, error) {
	if err := os.MkdirAll(catalogsDir, 0o755); err != nil {
		return nil, fmt.Errorf("extractor: mkdir %s: %w", catalogsDir, err)
	}
	primary := filepath.Join(catalogsDir, cmd.OutputFile)
	referencesOutput := filepath.Join(catalogsDir, "references.json")
	filesOutput := filepath.Join(catalogsDir, "files.json")

	repl := map[string]string{
		"{root}":              args.Root,
		"{output}":            primary,
		"{shared}":            args.Shared,
		"{touched}":           args.Touched,
		"{extensions}":        args.Extensions,
		"{references_output}": referencesOutput,
		"{files_output}":      filesOutput,
	}
	if args.MinBodyLines > 0 {
		repl["{min_body_lines}"] = strconv.Itoa(args.MinBodyLines)
	}

	argv := make([]string, 0, len(cmd.Invocation))
	for _, tok := range cmd.Invocation {
		argv = append(argv, substitute(tok, repl))
	}

	cli := map[string]any{"root": args.Root}
	for _, oa := range cmd.OptionalArgs {
		if !whenSatisfied(oa.When, args) {
			continue
		}
		argv = append(argv, oa.Flag)
		if oa.Placeholder != "" {
			argv = append(argv, substitute(oa.Placeholder, repl))
		}
		recordArg(cli, oa.When, args)
	}

	if err := checkUnresolved(argv); err != nil {
		return nil, err
	}

	exe, err := exec.LookPath(argv[0])
	if err != nil {
		return nil, fmt.Errorf("extractor: %s not found on PATH: %w", argv[0], err)
	}
	subprocess := exec.CommandContext(ctx, exe, argv[1:]...)
	subprocess.Dir = extractorDir
	subprocess.Stderr = os.Stderr
	subprocess.Stdout = os.Stderr // diagnostic output; --output writes the catalog file directly
	if err := subprocess.Run(); err != nil {
		return nil, fmt.Errorf("extractor: subprocess (%s): %w", strings.Join(argv, " "), err)
	}
	if _, err := os.Stat(primary); err != nil {
		return nil, fmt.Errorf("extractor: %s did not produce %s: %w", argv[0], primary, err)
	}

	results := []Result{{Catalog: cmd.Catalog, OutputPath: primary, CLIArgs: cli}}
	for _, sib := range cmd.SiblingOutputs {
		if !whenSatisfied(sib.When, args) {
			continue
		}
		sibPath := filepath.Join(catalogsDir, sib.File)
		if _, err := os.Stat(sibPath); err != nil {
			return nil, fmt.Errorf("extractor: sibling %s missing after %s: %w", sib.File, argv[0], err)
		}
		results = append(results, Result{Catalog: sib.Catalog, OutputPath: sibPath, CLIArgs: cli})
	}
	return results, nil
}

func substitute(token string, repl map[string]string) string {
	for k, v := range repl {
		token = strings.ReplaceAll(token, k, v)
	}
	return token
}

func checkUnresolved(argv []string) error {
	for _, a := range argv {
		if strings.Contains(a, "{") && strings.Contains(a, "}") {
			return fmt.Errorf("extractor: unresolved placeholder in argv: %q", a)
		}
	}
	return nil
}

func whenSatisfied(when string, args Args) bool {
	switch when {
	case "shared_set":
		return args.Shared != ""
	case "touched_set":
		return args.Touched != ""
	case "include_tests_set":
		return args.IncludeTests
	case "references_enabled":
		return args.EmitReferences
	case "files_enabled":
		return args.EmitFiles
	case "min_body_lines_set":
		return args.MinBodyLines > 0
	case "extensions_set":
		return args.Extensions != ""
	}
	return false
}

func recordArg(cli map[string]any, when string, args Args) {
	switch when {
	case "shared_set":
		cli["shared"] = args.Shared
	case "touched_set":
		cli["touched"] = args.Touched
	case "include_tests_set":
		cli["include_tests"] = true
	case "references_enabled":
		cli["emit_references"] = true
	case "files_enabled":
		cli["emit_files"] = true
	case "min_body_lines_set":
		cli["min_body_lines"] = args.MinBodyLines
	case "extensions_set":
		cli["extensions"] = args.Extensions
	}
}

// ErrNoCommand signals the caller passed an empty manifest selection — used
// by the CLI layer to distinguish "extractor invocation failed" from
// "extractor was filtered out by --catalog flags."
var ErrNoCommand = errors.New("extractor: no command matched")
