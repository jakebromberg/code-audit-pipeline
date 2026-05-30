// Package frontmatter parses the `#! key: value` header block at the top of
// pipeline/queries/*.jq files. The grammar is defined by ADR-0002.
package frontmatter

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Header is the parsed result. Field ordering matches the documented
// front-matter order (query, shape, catalog, arg*, env*, formats, desc, version, engine).
type Header struct {
	Query   string
	Shape   []string // 1 or 2 values from {cluster, pair, metric}
	Catalog []string // 1..N catalog-kind strings; first is positional input
	Args    []ArgDecl
	Envs    []EnvDecl
	Formats []string // subset of {text, jsonl}
	Desc    string
	Version int    // 1 when absent
	Engine  string // "" (default: embedded gojq) or "jq" (shell-out)
}

type ArgDecl struct {
	Name     string
	Type     string // number | string | json
	Default  string // literal default or "" when required
	Required bool
}

type EnvDecl struct {
	Name    string
	Type    string // number | string | json
	Default string // default value as written (may be the literal "")
}

var shapeSet = map[string]bool{"cluster": true, "pair": true, "metric": true}
var formatSet = map[string]bool{"text": true, "jsonl": true}
var typeSet = map[string]bool{"number": true, "string": true, "json": true}

// Parse reads a query file's front-matter block. Returns a Header on success
// or an error describing the first violation encountered. Lines after the
// initial #!-prefixed block are not consumed.
func Parse(r io.Reader) (*Header, error) {
	h := &Header{Version: 1}
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	seen := map[string]bool{}
	inBlock := false

	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimRight(line, " \t")
		if strings.HasPrefix(trimmed, "#! ") {
			inBlock = true
			if err := h.consume(trimmed[3:], seen); err != nil {
				return nil, err
			}
			continue
		}
		if inBlock {
			break
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("frontmatter: scan: %w", err)
	}

	if err := h.validate(); err != nil {
		return nil, err
	}
	return h, nil
}

func (h *Header) consume(rest string, seen map[string]bool) error {
	colon := strings.IndexByte(rest, ':')
	if colon < 0 {
		return fmt.Errorf("frontmatter: missing ':' in line: %q", rest)
	}
	key := strings.TrimSpace(rest[:colon])
	value := strings.TrimSpace(rest[colon+1:])

	switch key {
	case "query":
		if seen[key] {
			return fmt.Errorf("frontmatter: duplicate key %q", key)
		}
		seen[key] = true
		h.Query = value
	case "shape":
		if seen[key] {
			return fmt.Errorf("frontmatter: duplicate key %q", key)
		}
		seen[key] = true
		h.Shape = splitCommaList(value)
		for _, s := range h.Shape {
			if !shapeSet[s] {
				return fmt.Errorf("frontmatter: unknown shape %q", s)
			}
		}
	case "catalog":
		if seen[key] {
			return fmt.Errorf("frontmatter: duplicate key %q", key)
		}
		seen[key] = true
		h.Catalog = splitCommaList(value)
	case "arg":
		decl, err := parseTriplet(value)
		if err != nil {
			return fmt.Errorf("frontmatter: arg: %w", err)
		}
		required := decl[2] == "required"
		def := decl[2]
		if required {
			def = ""
		}
		h.Args = append(h.Args, ArgDecl{Name: decl[0], Type: decl[1], Default: def, Required: required})
	case "env":
		decl, err := parseTriplet(value)
		if err != nil {
			return fmt.Errorf("frontmatter: env: %w", err)
		}
		h.Envs = append(h.Envs, EnvDecl{Name: decl[0], Type: decl[1], Default: unquote(decl[2])})
	case "formats":
		if seen[key] {
			return fmt.Errorf("frontmatter: duplicate key %q", key)
		}
		seen[key] = true
		h.Formats = splitCommaList(value)
		for _, f := range h.Formats {
			if !formatSet[f] {
				return fmt.Errorf("frontmatter: unknown format %q", f)
			}
		}
	case "desc":
		if seen[key] {
			return fmt.Errorf("frontmatter: duplicate key %q", key)
		}
		seen[key] = true
		h.Desc = value
	case "version":
		if seen[key] {
			return fmt.Errorf("frontmatter: duplicate key %q", key)
		}
		seen[key] = true
		v, err := strconv.Atoi(value)
		if err != nil {
			return fmt.Errorf("frontmatter: version not integer: %q", value)
		}
		if v != 1 {
			return fmt.Errorf("frontmatter: version %d not supported by this audit-version (only v1)", v)
		}
		h.Version = v
	case "engine":
		if seen[key] {
			return fmt.Errorf("frontmatter: duplicate key %q", key)
		}
		seen[key] = true
		if value != "jq" {
			return fmt.Errorf("frontmatter: engine must be %q, got %q", "jq", value)
		}
		h.Engine = value
	default:
		return fmt.Errorf("frontmatter: unknown key %q", key)
	}
	return nil
}

func (h *Header) validate() error {
	if h.Query == "" {
		return fmt.Errorf("frontmatter: missing required key %q", "query")
	}
	if len(h.Shape) == 0 {
		return fmt.Errorf("frontmatter: missing required key %q", "shape")
	}
	if len(h.Catalog) == 0 {
		return fmt.Errorf("frontmatter: missing required key %q", "catalog")
	}
	if len(h.Formats) == 0 {
		return fmt.Errorf("frontmatter: missing required key %q", "formats")
	}
	if h.Desc == "" {
		return fmt.Errorf("frontmatter: missing required key %q", "desc")
	}
	for _, a := range h.Args {
		if !typeSet[a.Type] {
			return fmt.Errorf("frontmatter: arg %q has unknown type %q", a.Name, a.Type)
		}
	}
	for _, e := range h.Envs {
		if !typeSet[e.Type] {
			return fmt.Errorf("frontmatter: env %q has unknown type %q", e.Name, e.Type)
		}
	}
	return nil
}

func splitCommaList(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		t := strings.TrimSpace(p)
		if t != "" {
			out = append(out, t)
		}
	}
	return out
}

func parseTriplet(s string) ([3]string, error) {
	fields := strings.Fields(s)
	if len(fields) != 3 {
		return [3]string{}, fmt.Errorf("expected 3 whitespace-separated tokens, got %d in %q", len(fields), s)
	}
	return [3]string{fields[0], fields[1], fields[2]}, nil
}

// unquote strips a single pair of surrounding double quotes from s when both
// ends carry one. Env defaults are written in double-quoted form per the
// grammar (`env: NAME string "value"`); arg defaults for numbers are written
// bare. The function is a no-op for unquoted input.
func unquote(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	return s
}
