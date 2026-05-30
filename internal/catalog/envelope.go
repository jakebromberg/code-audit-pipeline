// Package catalog reads the #141 "catalog envelope" — the top-level wrapper
// object on each catalog file holding schema_version, extractor metadata,
// and entries. ADR-0007 amends ADR-0001: the catalog file is authoritative,
// `.audit/meta.json` caches a derived `envelope_summary`. Refresh on every
// `audit status` / `audit query` to catch hand-edits.
package catalog

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// EnvelopeSummary mirrors what `meta.json.catalogs[<kind>].envelope_summary`
// caches. Field set follows ADR-0007. Forward-compatible: unknown top-level
// keys are preserved in Extra so a future #141 schema bump (e.g., a
// fingerprint_v field) shows up under audit status without a binary change.
type EnvelopeSummary struct {
	SchemaVersion string          `json:"schema_version,omitempty"`
	Extractor     json.RawMessage `json:"extractor,omitempty"`
	FingerprintV  string          `json:"fingerprint_v,omitempty"`
	GeneratedAt   string          `json:"generated_at,omitempty"`
	Extra         map[string]json.RawMessage `json:"-"`
}

// ReadEnvelope opens path, parses the top-level object as an envelope summary,
// and computes the sha256 of the file contents. The `entries` array is not
// loaded — the function reads the whole file (catalogs are small to medium;
// streaming the head would save little) but skips the entries array when
// extracting summary fields.
func ReadEnvelope(path string) (*EnvelopeSummary, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", fmt.Errorf("catalog: %w", err)
	}
	defer f.Close()
	hasher := sha256.New()
	data, err := io.ReadAll(io.TeeReader(f, hasher))
	if err != nil {
		return nil, "", fmt.Errorf("catalog: %s: %w", path, err)
	}
	sum := hex.EncodeToString(hasher.Sum(nil))

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		// v1.0 bare-array catalogs have no envelope — treat as empty.
		// Re-test by unmarshaling into a JSON value to surface real syntax errors.
		var arr []json.RawMessage
		if err2 := json.Unmarshal(data, &arr); err2 == nil {
			return &EnvelopeSummary{}, sum, nil
		}
		return nil, "", fmt.Errorf("catalog: %s: %w", path, err)
	}
	es := &EnvelopeSummary{Extra: map[string]json.RawMessage{}}
	for k, v := range raw {
		switch k {
		case "schema_version":
			_ = json.Unmarshal(v, &es.SchemaVersion)
		case "extractor":
			es.Extractor = v
		case "fingerprint_v":
			_ = json.Unmarshal(v, &es.FingerprintV)
		case "generated_at":
			_ = json.Unmarshal(v, &es.GeneratedAt)
		case "entries":
			// skip — large
		default:
			es.Extra[k] = v
		}
	}
	return es, sum, nil
}
