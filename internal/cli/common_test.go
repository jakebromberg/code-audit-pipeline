package cli

import (
	"strings"
	"testing"

	"github.com/jakebromberg/code-audit-pipeline/internal/frontmatter"
)

// TestBuildBindings_NumberArgCoercedToJSON locks in the #216 fix: when a
// query declares `arg: <name> number` and the caller passes the value via
// --arg (which arrives as a string), buildBindings must coerce it to a
// JSON number so gojq's numeric comparisons (e.g. `$threshold >= 0.7`)
// don't silently false-miss against a string operand.
func TestBuildBindings_NumberArgCoercedToJSON(t *testing.T) {
	h := &frontmatter.Header{
		Args: []frontmatter.ArgDecl{
			{Name: "threshold", Type: "number", Required: true},
		},
	}
	bs, err := buildBindings(h, stringList{"threshold=0.7"}, nil)
	if err != nil {
		t.Fatalf("buildBindings: %v", err)
	}
	if len(bs) != 1 {
		t.Fatalf("expected 1 binding, got %d", len(bs))
	}
	b := bs[0]
	if b.Name != "threshold" {
		t.Errorf("Name: got %q, want %q", b.Name, "threshold")
	}
	if !b.IsJSON {
		t.Errorf("IsJSON: got false, want true (numeric --arg must be coerced)")
	}
	f, ok := b.Value.(float64)
	if !ok {
		t.Fatalf("Value: got %T (%v), want float64", b.Value, b.Value)
	}
	if f != 0.7 {
		t.Errorf("Value: got %v, want 0.7", f)
	}
}

// TestBuildBindings_NumberArgIntegerCoerced confirms integer-looking
// values also coerce cleanly (gojq treats ints as float64).
func TestBuildBindings_NumberArgIntegerCoerced(t *testing.T) {
	h := &frontmatter.Header{
		Args: []frontmatter.ArgDecl{
			{Name: "count", Type: "number", Required: true},
		},
	}
	bs, err := buildBindings(h, stringList{"count=10"}, nil)
	if err != nil {
		t.Fatalf("buildBindings: %v", err)
	}
	if !bs[0].IsJSON {
		t.Errorf("IsJSON: got false, want true")
	}
	if f, ok := bs[0].Value.(float64); !ok || f != 10 {
		t.Errorf("Value: got %v (%T), want float64(10)", bs[0].Value, bs[0].Value)
	}
}

// TestBuildBindings_NumberArgRejectsGarbage confirms unparseable numeric
// --arg values still fail loudly (typecheckBinding behavior preserved).
func TestBuildBindings_NumberArgRejectsGarbage(t *testing.T) {
	h := &frontmatter.Header{
		Args: []frontmatter.ArgDecl{
			{Name: "threshold", Type: "number", Required: true},
		},
	}
	_, err := buildBindings(h, stringList{"threshold=not-a-number"}, nil)
	if err == nil {
		t.Fatal("expected error for non-numeric --arg value, got nil")
	}
	if !strings.Contains(err.Error(), "threshold") || !strings.Contains(err.Error(), "number") {
		t.Errorf("error %q should mention arg name and type", err.Error())
	}
}

// TestBuildBindings_StringArgUnchanged confirms string-typed --arg values
// pass through as Go strings with IsJSON=false.
func TestBuildBindings_StringArgUnchanged(t *testing.T) {
	h := &frontmatter.Header{
		Args: []frontmatter.ArgDecl{
			{Name: "label", Type: "string", Required: true},
		},
	}
	bs, err := buildBindings(h, stringList{"label=hello"}, nil)
	if err != nil {
		t.Fatalf("buildBindings: %v", err)
	}
	if bs[0].IsJSON {
		t.Errorf("IsJSON: got true, want false for string-typed arg")
	}
	if s, ok := bs[0].Value.(string); !ok || s != "hello" {
		t.Errorf("Value: got %v (%T), want string(%q)", bs[0].Value, bs[0].Value, "hello")
	}
}

// TestBuildBindings_JSONArgUnchanged confirms --argjson values are not
// double-coerced and pass through as parsed JSON.
func TestBuildBindings_JSONArgUnchanged(t *testing.T) {
	h := &frontmatter.Header{
		Args: []frontmatter.ArgDecl{
			{Name: "threshold", Type: "number", Required: true},
		},
	}
	bs, err := buildBindings(h, nil, stringList{"threshold=0.7"})
	if err != nil {
		t.Fatalf("buildBindings: %v", err)
	}
	if !bs[0].IsJSON {
		t.Errorf("IsJSON: got false, want true")
	}
	if f, ok := bs[0].Value.(float64); !ok || f != 0.7 {
		t.Errorf("Value: got %v (%T), want float64(0.7)", bs[0].Value, bs[0].Value)
	}
}

// TestBuildBindings_NumberArgAndArgjsonEquivalent is the regression: the
// resulting bindings must be byte-equivalent (same Go types, same value,
// same IsJSON) whether the caller used --arg or --argjson for a number.
func TestBuildBindings_NumberArgAndArgjsonEquivalent(t *testing.T) {
	h := &frontmatter.Header{
		Args: []frontmatter.ArgDecl{
			{Name: "threshold", Type: "number", Required: true},
		},
	}
	viaArg, err := buildBindings(h, stringList{"threshold=0.7"}, nil)
	if err != nil {
		t.Fatalf("--arg: %v", err)
	}
	viaArgjson, err := buildBindings(h, nil, stringList{"threshold=0.7"})
	if err != nil {
		t.Fatalf("--argjson: %v", err)
	}
	if viaArg[0].IsJSON != viaArgjson[0].IsJSON {
		t.Errorf("IsJSON mismatch: --arg=%v --argjson=%v", viaArg[0].IsJSON, viaArgjson[0].IsJSON)
	}
	if viaArg[0].Value != viaArgjson[0].Value {
		t.Errorf("Value mismatch: --arg=%v (%T) --argjson=%v (%T)",
			viaArg[0].Value, viaArg[0].Value, viaArgjson[0].Value, viaArgjson[0].Value)
	}
}

// TestBuildBindings_NumberArgDefaultIsJSON confirms the default-value
// path also produces a JSON number when the decl is number-typed.
func TestBuildBindings_NumberArgDefaultIsJSON(t *testing.T) {
	h := &frontmatter.Header{
		Args: []frontmatter.ArgDecl{
			{Name: "threshold", Type: "number", Default: "0.5", Required: false},
		},
	}
	bs, err := buildBindings(h, nil, nil)
	if err != nil {
		t.Fatalf("buildBindings: %v", err)
	}
	if !bs[0].IsJSON {
		t.Errorf("IsJSON: got false, want true for number-typed default")
	}
	if f, ok := bs[0].Value.(float64); !ok || f != 0.5 {
		t.Errorf("Value: got %v (%T), want float64(0.5)", bs[0].Value, bs[0].Value)
	}
}
