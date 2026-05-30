package frontmatter

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseMinimal(t *testing.T) {
	src := `# comment
#! query: exact-duplicates
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Cluster types whose shape_sig is identical.

include "_canonical";
`
	h, err := Parse(strings.NewReader(src))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if h.Query != "exact-duplicates" {
		t.Errorf("Query = %q, want exact-duplicates", h.Query)
	}
	if !reflect.DeepEqual(h.Shape, []string{"cluster"}) {
		t.Errorf("Shape = %v", h.Shape)
	}
	if !reflect.DeepEqual(h.Catalog, []string{"type-catalog"}) {
		t.Errorf("Catalog = %v", h.Catalog)
	}
	if !reflect.DeepEqual(h.Formats, []string{"text", "jsonl"}) {
		t.Errorf("Formats = %v", h.Formats)
	}
	if h.Desc != "Cluster types whose shape_sig is identical." {
		t.Errorf("Desc = %q", h.Desc)
	}
	if h.Version != 1 {
		t.Errorf("Version default = %d, want 1", h.Version)
	}
	if h.Engine != "" {
		t.Errorf("Engine default = %q, want empty", h.Engine)
	}
}

func TestParseDualShape(t *testing.T) {
	src := `#! query: function-duplicates
#! shape: cluster, pair
#! catalog: function-catalog
#! arg: threshold number required
#! formats: text, jsonl
#! desc: Function-body duplicates.
`
	h, err := Parse(strings.NewReader(src))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !reflect.DeepEqual(h.Shape, []string{"cluster", "pair"}) {
		t.Errorf("Shape = %v", h.Shape)
	}
	if len(h.Args) != 1 || h.Args[0].Name != "threshold" || h.Args[0].Type != "number" || !h.Args[0].Required {
		t.Errorf("Args = %+v", h.Args)
	}
}

func TestParseTwoCatalogs(t *testing.T) {
	src := `#! query: cross-catalog-name-collisions
#! shape: cluster
#! catalog: type-catalog, type-catalog
#! env: LEFT_LABEL string "left"
#! env: RIGHT_LABEL string "right"
#! formats: text, jsonl
#! desc: Names that appear in both catalogs.
`
	h, err := Parse(strings.NewReader(src))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if !reflect.DeepEqual(h.Catalog, []string{"type-catalog", "type-catalog"}) {
		t.Errorf("Catalog = %v", h.Catalog)
	}
	if len(h.Envs) != 2 {
		t.Fatalf("Envs len = %d, want 2", len(h.Envs))
	}
	if h.Envs[0] != (EnvDecl{Name: "LEFT_LABEL", Type: "string", Default: "left"}) {
		t.Errorf("Envs[0] = %+v", h.Envs[0])
	}
}

func TestParseEnvEmptyDefault(t *testing.T) {
	src := `#! query: q
#! shape: metric
#! catalog: type-catalog
#! env: PACKAGE string ""
#! formats: text
#! desc: x.
`
	h, err := Parse(strings.NewReader(src))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if h.Envs[0].Default != "" {
		t.Errorf("Envs[0].Default = %q, want empty", h.Envs[0].Default)
	}
}

func TestParseEngineOptOut(t *testing.T) {
	src := `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! engine: jq
#! formats: text, jsonl
#! desc: x.
`
	h, err := Parse(strings.NewReader(src))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if h.Engine != "jq" {
		t.Errorf("Engine = %q, want jq", h.Engine)
	}
}

func TestParseErrors(t *testing.T) {
	cases := map[string]string{
		"missing query": `#! shape: cluster
#! catalog: type-catalog
#! formats: text
#! desc: x.
`,
		"missing shape": `#! query: q
#! catalog: type-catalog
#! formats: text
#! desc: x.
`,
		"missing catalog": `#! query: q
#! shape: cluster
#! formats: text
#! desc: x.
`,
		"missing formats": `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! desc: x.
`,
		"missing desc": `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! formats: text
`,
		"bad shape": `#! query: q
#! shape: bogus
#! catalog: type-catalog
#! formats: text
#! desc: x.
`,
		"bad format": `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! formats: xml
#! desc: x.
`,
		"bad arg triplet": `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! arg: only two
#! formats: text
#! desc: x.
`,
		"bad arg type": `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! arg: x bogus required
#! formats: text
#! desc: x.
`,
		"duplicate query": `#! query: q
#! query: q2
#! shape: cluster
#! catalog: type-catalog
#! formats: text
#! desc: x.
`,
		"unknown key": `#! query: q
#! bogus: value
#! shape: cluster
#! catalog: type-catalog
#! formats: text
#! desc: x.
`,
		"bad version": `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! version: 2
#! formats: text
#! desc: x.
`,
		"bad engine": `#! query: q
#! shape: cluster
#! catalog: type-catalog
#! engine: python
#! formats: text
#! desc: x.
`,
	}
	for name, src := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Parse(strings.NewReader(src)); err == nil {
				t.Errorf("expected error for %s, got nil", name)
			}
		})
	}
}
