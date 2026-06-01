package manifest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeManifest(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "manifest.toml")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestParseRealManifests(t *testing.T) {
	// Parse each of the three real manifests checked into the repo to confirm
	// the parser keeps in sync with the schema.
	for _, path := range []string{
		"../../extractors/typescript/manifest.toml",
		"../../extractors/swift/manifest.toml",
		"../../extractors/file-hashes/manifest.toml",
	} {
		t.Run(path, func(t *testing.T) {
			m, err := Parse(path)
			if err != nil {
				t.Fatalf("Parse(%s): %v", path, err)
			}
			if m.Extractor.Name == "" {
				t.Error("extractor.name empty")
			}
			if len(m.Commands) == 0 {
				t.Error("no [[command]] blocks")
			}
		})
	}
}

func TestParseValid(t *testing.T) {
	p := writeManifest(t, `schema_version = 1

[extractor]
name = "test"
language = "test"
version = "0.0.1"

[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
invocation = ["node", "x.mjs", "--output", "{output}"]
optional_args = [
  { flag = "--shared", placeholder = "{shared}", when = "shared_set" },
]
sibling_outputs = [
  { catalog = "references-graph", file = "references.json", when = "references_enabled" },
]

[runtime]
requires = ["node >= 18"]
`)
	m, err := Parse(p)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if m.Commands[0].OptionalArgs[0].When != "shared_set" {
		t.Errorf("when = %q", m.Commands[0].OptionalArgs[0].When)
	}
	if m.Commands[0].SiblingOutputs[0].Catalog != "references-graph" {
		t.Errorf("sibling catalog = %q", m.Commands[0].SiblingOutputs[0].Catalog)
	}
}

func TestParseErrors(t *testing.T) {
	cases := map[string]string{
		"missing schema_version": `[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]
`,
		"out-of-range schema_version": `schema_version = 99
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]
`,
		"missing extractor.name": `schema_version = 1
[extractor]
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]
`,
		"no commands": `schema_version = 1
[extractor]
name = "x"
version = "0.0.1"
`,
		"invocation missing {output}": `schema_version = 1
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x"]
`,
		"unknown when": `schema_version = 1
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]
optional_args = [{ flag = "--y", placeholder = "{y}", when = "bogus" }]
`,
	}
	for name, src := range cases {
		t.Run(name, func(t *testing.T) {
			p := writeManifest(t, src)
			if _, err := Parse(p); err == nil {
				t.Errorf("expected error for %s, got nil", name)
			}
		})
	}
}

// Test 5a — schema 1 without [runtime].bootstrap parses; Bootstrap is nil.
func TestParseSchema1WithoutBootstrap(t *testing.T) {
	p := writeManifest(t, `schema_version = 1
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]

[runtime]
requires = ["node >= 18"]
setup_hint = "run npm install"
`)
	m, err := Parse(p)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if m.SchemaVersion != SchemaVersion1 {
		t.Errorf("SchemaVersion = %d, want %d", m.SchemaVersion, SchemaVersion1)
	}
	if m.Runtime.Bootstrap != nil {
		t.Errorf("Bootstrap = %v, want nil", m.Runtime.Bootstrap)
	}
}

// Test 5b — schema 1 WITH [runtime].bootstrap is rejected at parse time.
func TestParseSchema1WithBootstrapRejected(t *testing.T) {
	p := writeManifest(t, `schema_version = 1
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]

[runtime]
bootstrap = ["npm", "install"]
`)
	_, err := Parse(p)
	if err == nil {
		t.Fatal("expected error for schema 1 + bootstrap, got nil")
	}
	if !strings.Contains(err.Error(), "schema_version") {
		t.Errorf("error should mention schema_version requirement: %v", err)
	}
}

// Test 6 — schema 2 with bootstrap parses; Bootstrap is the right slice.
func TestParseSchema2WithBootstrap(t *testing.T) {
	p := writeManifest(t, `schema_version = 2
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]

[runtime]
requires = ["node >= 18"]
bootstrap = ["npm", "install"]
setup_hint = "manual install fallback"
`)
	m, err := Parse(p)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if m.SchemaVersion != SchemaVersion2 {
		t.Errorf("SchemaVersion = %d, want %d", m.SchemaVersion, SchemaVersion2)
	}
	want := []string{"npm", "install"}
	if len(m.Runtime.Bootstrap) != len(want) ||
		m.Runtime.Bootstrap[0] != want[0] ||
		m.Runtime.Bootstrap[1] != want[1] {
		t.Errorf("Bootstrap = %v, want %v", m.Runtime.Bootstrap, want)
	}
}

// Test 7a — schema 2 WITHOUT bootstrap parses; Bootstrap is nil. Status will
// later show n-a for this extractor.
func TestParseSchema2WithoutBootstrap(t *testing.T) {
	p := writeManifest(t, `schema_version = 2
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]

[runtime]
requires = ["python >= 3.11"]
`)
	m, err := Parse(p)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if m.Runtime.Bootstrap != nil {
		t.Errorf("Bootstrap = %v, want nil", m.Runtime.Bootstrap)
	}
}

// Test 7b — schema 0 rejected.
func TestParseSchema0Rejected(t *testing.T) {
	p := writeManifest(t, `schema_version = 0
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]
`)
	_, err := Parse(p)
	if err == nil {
		t.Fatal("expected error for schema 0")
	}
}

// Test 7c — schema 3 rejected with clear range error.
func TestParseSchema3Rejected(t *testing.T) {
	p := writeManifest(t, `schema_version = 3
[extractor]
name = "x"
version = "0.0.1"
[[command]]
catalog = "c"
output_file = "c.json"
invocation = ["x", "--output", "{output}"]
`)
	_, err := Parse(p)
	if err == nil {
		t.Fatal("expected error for schema 3")
	}
	if !strings.Contains(err.Error(), "schema_version") {
		t.Errorf("error should mention schema_version: %v", err)
	}
}
