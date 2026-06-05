// Package manifest parses extractors/<lang>/manifest.toml per ADR-0002.
package manifest

import (
	"fmt"
	"os"
	"strings"

	"github.com/BurntSushi/toml"
)

// Schema version constants. Exported within the internal/manifest package so
// tests and downstream consumers can reference them without hard-coding
// literals. Range check at validate() uses MinSchemaVersion..MaxSchemaVersion.
const (
	SchemaVersion1   = 1
	SchemaVersion2   = 2
	MinSchemaVersion = SchemaVersion1
	MaxSchemaVersion = SchemaVersion2
)

type Manifest struct {
	SchemaVersion int            `toml:"schema_version"`
	Extractor     Extractor      `toml:"extractor"`
	Commands      []Command      `toml:"command"`
	Runtime       Runtime        `toml:"runtime"`
}

type Extractor struct {
	Name        string `toml:"name"`
	Language    string `toml:"language"`
	Version     string `toml:"version"`
	Description string `toml:"description"`
}

type Command struct {
	Catalog        string           `toml:"catalog"`
	OutputFile     string           `toml:"output_file"`
	Invocation     []string         `toml:"invocation"`
	OptionalArgs   []OptionalArg    `toml:"optional_args"`
	SiblingOutputs []SiblingOutput  `toml:"sibling_outputs"`
}

type OptionalArg struct {
	Flag        string `toml:"flag"`
	Placeholder string `toml:"placeholder"`
	When        string `toml:"when"`
}

type SiblingOutput struct {
	Catalog string `toml:"catalog"`
	File    string `toml:"file"`
	When    string `toml:"when"`
}

type Runtime struct {
	Requires  []string `toml:"requires"`
	SetupHint string   `toml:"setup_hint"`
	// Bootstrap, when non-empty, is the argv the binary runs once per
	// extractor source layout (after `code-audit init`, after `code-audit
	// init --upgrade`, and on the first `code-audit extract` of a freshly
	// auto-extracted brew install). Requires schema_version >= 2.
	Bootstrap []string `toml:"bootstrap"`
}

var validWhen = map[string]bool{
	"shared_set":              true,
	"touched_set":             true,
	"include_tests_set":       true,
	"references_enabled":      true,
	"files_enabled":           true,
	"min_body_lines_set":      true,
	"extensions_set":          true,
	"include_imports_enabled": true,
	"scan_header_set":         true,
}

// Parse reads and validates a manifest.toml at the given path.
func Parse(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	return ParseBytes(path, data)
}

// ParseBytes validates a manifest.toml provided as bytes. The pathHint
// is used in error messages only — it does not have to refer to an actual
// filesystem path. Use this when reading the manifest from an embedded
// fs.FS instead of disk, so the parse step runs before any on-disk
// mutations (avoids leaving lay-down state with no manifest-validated
// counterpart in state.json).
func ParseBytes(pathHint string, data []byte) (*Manifest, error) {
	var m Manifest
	if err := toml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("manifest: %s: %w", pathHint, err)
	}
	if err := m.validate(pathHint); err != nil {
		return nil, err
	}
	return &m, nil
}

// validate enforces the schema-version range and per-version field rules.
//
// Note: BurntSushi/toml silently ignores unknown top-level fields by
// default. When introducing schema_version > 2 that adds NEW required
// fields, bumping MaxSchemaVersion is not enough — wire the field through
// the Manifest struct and add a presence check here so a v2-capped binary
// reading a v3 manifest fails loudly (or rejects the manifest) rather
// than parsing silently with an undefined-default for the new field.
//
// To detect unknown fields in the future, switch from toml.Unmarshal to
// toml.NewDecoder + DisallowUnknownFields (BurntSushi v1.5+) or inspect
// MetaData.Undecoded() after decode.
func (m *Manifest) validate(path string) error {
	if m.SchemaVersion < MinSchemaVersion || m.SchemaVersion > MaxSchemaVersion {
		return fmt.Errorf("manifest: %s: schema_version must be %d-%d, got %d",
			path, MinSchemaVersion, MaxSchemaVersion, m.SchemaVersion)
	}
	if m.SchemaVersion == SchemaVersion1 && len(m.Runtime.Bootstrap) > 0 {
		return fmt.Errorf("manifest: %s: [runtime].bootstrap requires schema_version >= %d",
			path, SchemaVersion2)
	}
	if m.Extractor.Name == "" {
		return fmt.Errorf("manifest: %s: extractor.name required", path)
	}
	if m.Extractor.Version == "" {
		return fmt.Errorf("manifest: %s: extractor.version required", path)
	}
	if len(m.Commands) == 0 {
		return fmt.Errorf("manifest: %s: at least one [[command]] block required", path)
	}
	for i, c := range m.Commands {
		if c.Catalog == "" {
			return fmt.Errorf("manifest: %s: command[%d].catalog required", path, i)
		}
		if c.OutputFile == "" {
			return fmt.Errorf("manifest: %s: command[%d].output_file required", path, i)
		}
		if len(c.Invocation) == 0 {
			return fmt.Errorf("manifest: %s: command[%d].invocation required", path, i)
		}
		hasOutput := false
		for _, tok := range c.Invocation {
			if strings.Contains(tok, "{output}") {
				hasOutput = true
				break
			}
		}
		if !hasOutput {
			return fmt.Errorf("manifest: %s: command[%d].invocation must contain {output}", path, i)
		}
		for j, oa := range c.OptionalArgs {
			if !validWhen[oa.When] {
				return fmt.Errorf("manifest: %s: command[%d].optional_args[%d].when=%q is unknown", path, i, j, oa.When)
			}
		}
		for j, so := range c.SiblingOutputs {
			if !validWhen[so.When] {
				return fmt.Errorf("manifest: %s: command[%d].sibling_outputs[%d].when=%q is unknown", path, i, j, so.When)
			}
		}
	}
	return nil
}
