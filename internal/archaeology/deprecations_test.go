package archaeology

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestScanDeprecationsSwift(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "Foo.swift"), strings.Join([]string{
		`@available(*, deprecated, message: "use NewFoo instead")`,
		`public func oldFoo() {}`,
	}, "\n"))

	got, _, err := ScanDeprecations(context.Background(), root)
	if err != nil {
		t.Fatalf("ScanDeprecations: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1, got %d: %+v", len(got), got)
	}
	d := got[0]
	if d.Kind != "annotation" {
		t.Errorf("kind=%q want annotation", d.Kind)
	}
	if d.Message != "use NewFoo instead" {
		t.Errorf("message=%q", d.Message)
	}
	if d.Symbol != "oldFoo" {
		t.Errorf("symbol=%q want oldFoo", d.Symbol)
	}
}

func TestScanDeprecationsKotlinJava(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "Bar.kt"), strings.Join([]string{
		`@Deprecated("use NewBar")`,
		`class OldBar {}`,
	}, "\n"))

	got, _, err := ScanDeprecations(context.Background(), root)
	if err != nil {
		t.Fatalf("ScanDeprecations: %v", err)
	}
	if got[0].Kind != "annotation" || got[0].Message != "use NewBar" || got[0].Symbol != "OldBar" {
		t.Errorf("row=%+v", got[0])
	}
}

func TestScanDeprecationsCSharp(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "B.cs"), strings.Join([]string{
		`[Obsolete("use NewBaz")]`,
		`public class OldBaz {}`,
	}, "\n"))

	got, _, err := ScanDeprecations(context.Background(), root)
	if err != nil {
		t.Fatalf("ScanDeprecations: %v", err)
	}
	if got[0].Message != "use NewBaz" || got[0].Symbol != "OldBaz" {
		t.Errorf("row=%+v", got[0])
	}
}

func TestScanDeprecationsTSCommentForm(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "Q.ts"), strings.Join([]string{
		`/**`,
		` * @deprecated use newQuux`,
		` */`,
		`export function oldQuux() {}`,
	}, "\n"))

	got, _, err := ScanDeprecations(context.Background(), root)
	if err != nil {
		t.Fatalf("ScanDeprecations: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 row, got %d: %+v", len(got), got)
	}
	if got[0].Kind != "comment" || got[0].Message != "use newQuux" {
		t.Errorf("kind=%q message=%q", got[0].Kind, got[0].Message)
	}
	if got[0].Symbol != "oldQuux" {
		t.Errorf("symbol=%q want oldQuux", got[0].Symbol)
	}
}

func TestScanDeprecationsGenericCommentForm(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "L.go"), strings.Join([]string{
		`// Deprecated: use NewLegacy instead`,
		`func oldLegacy() {}`,
	}, "\n"))

	got, _, err := ScanDeprecations(context.Background(), root)
	if err != nil {
		t.Fatalf("ScanDeprecations: %v", err)
	}
	if len(got) != 1 || got[0].Message != "use NewLegacy instead" {
		t.Errorf("row=%+v", got)
	}
}

func TestScanDeprecationsIgnoresStringLiterals(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "Z.go"), strings.Join([]string{
		`package z`,
		`var msg = "Deprecated: not really"`,
		`var msg2 = "@deprecated nope"`,
		// Case-sensitive annotation forms inside string literals must also
		// not match — pins the review finding that the annotation regexes
		// ran against the whole line before the comment-start check.
		`var msg3 = "@Deprecated migration"`,
		`var msg4 = "[Obsolete: use NewThing]"`,
		`var msg5 = "@available(*, deprecated, message: foo)"`,
	}, "\n"))

	got, _, err := ScanDeprecations(context.Background(), root)
	if err != nil {
		t.Fatalf("ScanDeprecations: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("want 0 rows (all in string literals), got %d: %+v", len(got), got)
	}
}

func TestScanDeprecationsSortByFileLine(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "b.swift"), "@available(*, deprecated)\nfunc b() {}\n")
	writeFile(t, filepath.Join(root, "a.swift"), "@available(*, deprecated)\nfunc a() {}\n")

	got, _, err := ScanDeprecations(context.Background(), root)
	if err != nil {
		t.Fatalf("ScanDeprecations: %v", err)
	}
	if got[0].File != "a.swift" || got[1].File != "b.swift" {
		t.Errorf("sort order: %s, %s", got[0].File, got[1].File)
	}
}
