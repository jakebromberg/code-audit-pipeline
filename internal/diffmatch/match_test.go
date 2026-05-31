package diffmatch

import (
	"testing"
)

func ptrString(s string) *string { return &s }
func ptrInt(n int) *int          { return &n }

func TestFunctionBodyMatchesSubsetFinds(t *testing.T) {
	// Body in catalog contains all the removed lines, with extras.
	rows := []FunctionRow{
		{
			Name: "candidate", Kind: "function",
			Package: "PkgA", File: "a.swift", Line: 10,
			BodyHash:      ptrString("abc"),
			BodyLineCount: ptrInt(5),
			BodyLines:     []string{"one", "three", "two"}, // pre-sorted from extractor
		},
		{
			Name: "noise", Kind: "function",
			Package: "PkgB", File: "b.swift", Line: 1,
			BodyHash:  ptrString("def"),
			BodyLines: []string{"unrelated"},
		},
	}
	removed := []string{"one", "two"} // sorted
	matches := FunctionBodyMatches(rows, removed, 2, 0.5, "", 0)
	if len(matches) != 1 {
		t.Fatalf("want 1 match, got %d (%+v)", len(matches), matches)
	}
	m := matches[0]
	if m.Row.Name != "candidate" {
		t.Errorf("wrong row matched: %q", m.Row.Name)
	}
	if m.Intersection != 2 {
		t.Errorf("intersection: %d", m.Intersection)
	}
	if m.Union != 3 {
		t.Errorf("union: %d", m.Union)
	}
	if got, want := m.Jaccard, 2.0/3.0; got != want {
		t.Errorf("jaccard: %v want %v", got, want)
	}
}

func TestFunctionBodyMatchesSkipsNilBodyHash(t *testing.T) {
	rows := []FunctionRow{
		{
			Name: "oneliner", Package: "P", File: "x.swift", Line: 1,
			BodyHash:  nil,
			BodyLines: nil,
		},
	}
	if got := FunctionBodyMatches(rows, []string{"a"}, 1, 0.1, "", 0); len(got) != 0 {
		t.Errorf("want 0 (nil body_hash excluded), got %d", len(got))
	}
}

func TestFunctionBodyMatchesExcludesSelfLocation(t *testing.T) {
	rows := []FunctionRow{
		{
			Name: "edited", Package: "P", File: "x.swift", Line: 42,
			BodyHash:  ptrString("h"),
			BodyLines: []string{"a", "b", "c"},
		},
	}
	if got := FunctionBodyMatches(rows, []string{"a", "b"}, 2, 0.1, "x.swift", 42); len(got) != 0 {
		t.Errorf("want 0 (self-match excluded), got %d", len(got))
	}
	if got := FunctionBodyMatches(rows, []string{"a", "b"}, 2, 0.1, "other.swift", 42); len(got) != 1 {
		t.Errorf("want 1 (different file), got %d", len(got))
	}
}

func TestFunctionBodyMatchesRespectsMinJaccard(t *testing.T) {
	rows := []FunctionRow{
		{
			Name: "big", Package: "P", File: "x.swift", Line: 1,
			BodyHash:  ptrString("h"),
			BodyLines: []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"},
		},
	}
	// Removed set = {a, b}; intersection = 2; union = 10; jaccard = 0.2.
	if got := FunctionBodyMatches(rows, []string{"a", "b"}, 1, 0.5, "", 0); len(got) != 0 {
		t.Errorf("want 0 (below jaccard threshold), got %d", len(got))
	}
	if got := FunctionBodyMatches(rows, []string{"a", "b"}, 1, 0.1, "", 0); len(got) != 1 {
		t.Errorf("want 1 (above threshold), got %d", len(got))
	}
}

func TestFunctionBodyMatchesRanksByJaccardDesc(t *testing.T) {
	rows := []FunctionRow{
		{Name: "loose", Package: "P", File: "loose.swift", Line: 1, BodyHash: ptrString("1"),
			BodyLines: []string{"a", "b", "x", "y", "z"}},
		{Name: "tight", Package: "P", File: "tight.swift", Line: 1, BodyHash: ptrString("2"),
			BodyLines: []string{"a", "b"}},
	}
	got := FunctionBodyMatches(rows, []string{"a", "b"}, 2, 0.1, "", 0)
	if len(got) != 2 {
		t.Fatalf("want 2, got %d", len(got))
	}
	if got[0].Row.Name != "tight" {
		t.Errorf("expected tight first, got %s", got[0].Row.Name)
	}
}

func TestTypeShapeMatchesSubset(t *testing.T) {
	rows := []TypeRow{
		{
			Name: "Wide", Kind: "interface",
			Package: "P", File: "a.ts", Line: 1,
			FieldsStructured: []FieldStructured{
				{Name: "id", Type: "number"},
				{Name: "title", Type: "string"},
				{Name: "subtitle", Type: "string"},
				{Name: "extra", Type: "string"},
			},
		},
		{
			Name: "Narrow", Kind: "interface",
			Package: "P", File: "b.ts", Line: 1,
			FieldsStructured: []FieldStructured{
				{Name: "id", Type: "number"},
			},
		},
	}
	matches := TypeShapeMatches(rows, []string{"id", "title"}, 2, 0.1, "", 0)
	if len(matches) != 1 {
		t.Fatalf("want 1 (only Wide is superset), got %d", len(matches))
	}
	if matches[0].Row.Name != "Wide" {
		t.Errorf("got %s", matches[0].Row.Name)
	}
}

func TestTypeShapeMatchesFallsBackToFieldsArray(t *testing.T) {
	rows := []TypeRow{
		{
			Name: "OldSchema", Kind: "interface", Package: "P", File: "a.ts", Line: 1,
			Fields:           []string{"id:number", "title?:string"},
			FieldsStructured: nil, // pre-V7 §6.1
		},
	}
	matches := TypeShapeMatches(rows, []string{"id", "title"}, 2, 0.1, "", 0)
	if len(matches) != 1 {
		t.Fatalf("want 1, got %d", len(matches))
	}
}

func TestTypeShapeMatchesRequiresFullSubset(t *testing.T) {
	rows := []TypeRow{
		{
			Name: "Partial", Kind: "interface", Package: "P", File: "a.ts", Line: 1,
			FieldsStructured: []FieldStructured{
				{Name: "id"},
				{Name: "title"},
			},
		},
	}
	// Removed = {id, title, missing}; candidate covers only id+title.
	got := TypeShapeMatches(rows, []string{"id", "missing", "title"}, 1, 0.0, "", 0)
	if len(got) != 0 {
		t.Errorf("want 0 (not a full subset), got %d", len(got))
	}
}
