package manifest

import (
	"os"
	"path/filepath"
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
		"wrong schema_version": `schema_version = 2
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
