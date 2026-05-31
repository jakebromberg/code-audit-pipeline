package diffmatch

import (
	"reflect"
	"testing"
)

func TestExtractRemovedFieldNamesSwiftVarLet(t *testing.T) {
	in := []string{
		"public var foo: String",
		"  private static let bar: Int = 3",
		"weak var delegate: AnyObject?",
	}
	got := ExtractRemovedFieldNames(in)
	want := []string{"bar", "delegate", "foo"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestExtractRemovedFieldNamesTSInterface(t *testing.T) {
	in := []string{
		"id: number;",
		"title?: string;",
		"readonly hasPriority: boolean;",
	}
	got := ExtractRemovedFieldNames(in)
	want := []string{"hasPriority", "id", "title"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestExtractRemovedFieldNamesIgnoresNonFieldLines(t *testing.T) {
	in := []string{
		"func setUp() {",
		"}",
		"let x = 1 // an assignment, not a field decl",
	}
	// `let x = 1` lacks the `: TYPE` clause; the tightened regex rejects it
	// so the false-positive single-name match against any catalog type
	// with field `x` (e.g., CGPoint) doesn't fire.
	got := ExtractRemovedFieldNames(in)
	if len(got) != 0 {
		t.Errorf("got %v, want []", got)
	}
}

func TestExtractRemovedFieldNamesIgnoresSwitchAndLabelSyntax(t *testing.T) {
	in := []string{
		"default:",
		"case foo:",
		"loopLabel:",
		"URL:",
	}
	// All four are colon-bearing but lack a `: TYPE` clause; the tightened
	// regex rejects all so the false-positive single-name path is closed.
	got := ExtractRemovedFieldNames(in)
	if len(got) != 0 {
		t.Errorf("got %v, want []", got)
	}
}

func TestExtractRemovedFieldNamesDedupes(t *testing.T) {
	in := []string{
		"var foo: String",
		"var foo: Int", // same name twice
	}
	got := ExtractRemovedFieldNames(in)
	want := []string{"foo"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}
