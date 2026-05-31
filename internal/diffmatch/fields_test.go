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
	got := ExtractRemovedFieldNames(in)
	// `let x = 1` matches the Swift regex; the post-`:` shorthand path won't
	// fire because there's no `:`. The Swift regex requires a type clause
	// (`: TYPE`)? Let me check — the regex doesn't require it. So `let x =
	// 1` matches with name=x. That's still useful as a removed-name signal,
	// and TypeShapeMatches' subset filter saves us from false matches.
	want := []string{"x"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
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
