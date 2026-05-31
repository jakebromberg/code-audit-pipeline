package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/jakebromberg/code-audit-pipeline/internal/auditdir"
	"github.com/jakebromberg/code-audit-pipeline/internal/engine"
	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
)

// slurpfileVar maps a catalog kind to the gojq variable name when mounted as
// a slurpfile. Mirrors the convention real queries use.
var slurpfileVar = map[string]string{
	"type-catalog":     "types",
	"function-catalog": "functions",
	"references-graph": "refs",
	"files":            "files",
	"file-hashes":      "hashes",
}

// stringList implements flag.Value for repeatable flags.
type stringList []string

func (s *stringList) String() string     { return fmt.Sprint([]string(*s)) }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

// buildBindings validates --arg / --argjson against the query's front-matter
// args, applies defaults, and rejects undeclared bindings.
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
		// Coerce string-form --arg values to JSON numbers when the decl is
		// number-typed. Without this, gojq treats `$x` as a jq string and
		// `$x >= 0.7` silently false-misses. See #216.
		if decl.Type == "number" && !b.IsJSON {
			s, _ := b.Value.(string)
			f, err := parseFiniteFloat(s)
			if err != nil {
				// typecheckBinding already validated this; defensive only.
				return nil, fmt.Errorf("arg %s declared number, got %q: %w", decl.Name, s, err)
			}
			b.Value = f
			b.IsJSON = true
		}
		out = append(out, b)
	}
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
		f, err := parseFiniteFloat(def)
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
			s, _ := b.Value.(string)
			if _, err := parseFiniteFloat(s); err != nil {
				return fmt.Errorf("arg %s declared number, got %q: %w", decl.Name, s, err)
			}
		}
	case "string":
	case "json":
		if !b.IsJSON {
			return fmt.Errorf("arg %s declared json, requires --argjson", decl.Name)
		}
	}
	return nil
}

// parseFiniteFloat wraps strconv.ParseFloat and additionally rejects NaN and
// ±Inf, which ParseFloat happily accepts for the literal strings "NaN",
// "Inf", "+Inf", "-Inf". Non-finite values pass typecheck but blow up later
// in engine.Run at json.Marshal with a cryptic "unsupported value" error.
func parseFiniteFloat(s string) (float64, error) {
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, err
	}
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, fmt.Errorf("non-finite numeric value not allowed")
	}
	return f, nil
}

// wireCatalogs resolves the positional catalog input and the slurpfile
// mounts from the front-matter declaration. Per-query override is via
// --catalog (one value per declared kind, in order). When no override is
// given, paths come from .audit/ cache.
func wireCatalogs(absRoot string, h *frontmatter.Header, overrides stringList) (string, []engine.Slurpfile, error) {
	declared := h.Catalog
	if len(overrides) > 0 && len(overrides) != len(declared) {
		return "", nil, fmt.Errorf("--catalog given %d times but query declares %d catalog inputs", len(overrides), len(declared))
	}

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

	// Open the .audit/ cache at most once per call. Each query may declare
	// multiple catalog inputs; report runs invoke wireCatalogs per query,
	// so amortising the open here saves N opens per query × M queries.
	var cache *auditdir.Cache
	resolvePath := func(idx int, kind string) (string, error) {
		if idx < len(overrides) {
			return overrides[idx], nil
		}
		if cache == nil {
			c, err := auditdir.Open(absRoot, Version)
			if err != nil {
				return "", err
			}
			cache = c
		}
		p, ok := cache.CatalogPath(kind)
		if !ok {
			return "", fmt.Errorf("catalog %q not cached under .audit/ — run `code-audit extract` or pass --catalog <path>", kind)
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

func supportsFormat(declared []string, want string) bool {
	for _, f := range declared {
		if f == want {
			return true
		}
	}
	return false
}
