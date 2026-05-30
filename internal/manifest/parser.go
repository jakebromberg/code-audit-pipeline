// Package manifest parses extractors/<lang>/manifest.toml per ADR-0002.
package manifest

import (
	"fmt"
	"os"
	"strings"

	"github.com/BurntSushi/toml"
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
}

var validWhen = map[string]bool{
	"shared_set":          true,
	"touched_set":         true,
	"include_tests_set":   true,
	"references_enabled":  true,
	"files_enabled":       true,
	"min_body_lines_set":  true,
	"extensions_set":      true,
}

// Parse reads and validates a manifest.toml at the given path.
func Parse(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	var m Manifest
	if err := toml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("manifest: %s: %w", path, err)
	}
	if err := m.validate(path); err != nil {
		return nil, err
	}
	return &m, nil
}

func (m *Manifest) validate(path string) error {
	if m.SchemaVersion != 1 {
		return fmt.Errorf("manifest: %s: schema_version must be 1, got %d", path, m.SchemaVersion)
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
