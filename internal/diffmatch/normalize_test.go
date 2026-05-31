package diffmatch

import (
	"reflect"
	"testing"
)

func TestNormalizeTextStripsBlockComments(t *testing.T) {
	in := "let x = 1\n/* commented\nspan */let y = 2\n"
	got := NormalizeText(in)
	// Block comment is removed, leaving "let x = 1" and "let y = 2".
	want := []string{"let x = 1", "let y = 2"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestNormalizeTextStripsLineComments(t *testing.T) {
	in := "let x = 1 // counter\nlet y = 2//\n"
	got := NormalizeText(in)
	want := []string{"let x = 1", "let y = 2"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestNormalizeTextCollapsesWhitespace(t *testing.T) {
	in := "  let   x    =\t1   \n\t\tlet y = 2\n"
	got := NormalizeText(in)
	want := []string{"let x = 1", "let y = 2"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestNormalizeTextDropsBlanksAndDedupes(t *testing.T) {
	in := "a\n\nb\na\n   \nb\n"
	got := NormalizeText(in)
	want := []string{"a", "b"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestNormalizeTextSortsOutput(t *testing.T) {
	in := "z\nm\na\n"
	got := NormalizeText(in)
	want := []string{"a", "m", "z"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestNormalizeAgreesWithNormalizeText(t *testing.T) {
	lines := []string{"  let x = 1 // x", "/*c*/let y = 2"}
	a := Normalize(lines)
	b := NormalizeText("  let x = 1 // x\n/*c*/let y = 2")
	if !reflect.DeepEqual(a, b) {
		t.Errorf("Normalize=%v NormalizeText=%v", a, b)
	}
}
