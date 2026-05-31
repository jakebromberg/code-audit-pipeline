// Package archaeology gathers the substrate-level context blob that lens
// agents and the skeptic-with-evidence pass load as pre-context: open issues,
// recent PR diffs, TODO/FIXME inventory, deprecation markers, ADR text, and
// repo CLAUDE.md rule text.
//
// The bundle is a single JSON document; per-PR diffs are spilled to sibling
// files so the JSON stays parseable. See plans/issue-229-archaeology-bundler-plan.md
// for the design.
package archaeology

import "time"

// SchemaVersion is the bundle schema version emitted in archaeology.json.
// Independent of catalog schema versions; downstream consumers must treat
// the two as separate schema families.
const SchemaVersion = "1"

// Bundle is the on-disk archaeology.json shape.
type Bundle struct {
	SchemaVersion string                      `json:"schema_version"`
	GeneratedAt   time.Time                   `json:"generated_at"`
	Window        Window                      `json:"window"`
	Repo          string                      `json:"repo,omitempty"`
	Root          string                      `json:"root"`
	Sources       map[string]SourceProvenance `json:"sources"`

	OpenIssues   []Issue       `json:"open_issues"`
	RecentPRs    []PR          `json:"recent_prs"`
	TODOs        []TODO        `json:"todos"`
	Deprecations []Deprecation `json:"deprecations"`
	ADRs         []ADR         `json:"adrs"`
	RuleText     []RuleText    `json:"rule_text"`
}

// Window declares the recency window used to filter issues and PRs.
type Window struct {
	Days  int       `json:"days"`
	Since time.Time `json:"since"`
}

// SourceProvenance carries per-source status so consumers can distinguish
// "source ran and found nothing" from "source was skipped" from "source failed".
//
// Three terminal states:
//
//   - skipped=true, ok=true               — user passed --no-<source>; the skip
//     itself succeeded. Count is 0.
//   - skipped=false, ok=true              — source ran. Count is the row count
//     (may be 0 when no rows exist).
//   - skipped=false, ok=false             — source ran and failed. Error carries
//     the underlying message; the bundle's section array is empty.
//
// Consumers should check skipped first, then ok.
type SourceProvenance struct {
	Tool    string `json:"tool"`
	OK      bool   `json:"ok"`
	Count   int    `json:"count"`
	Skipped bool   `json:"skipped"`
	Error   string `json:"error,omitempty"`
}

// Issue is one open GitHub issue.
type Issue struct {
	Number    int       `json:"number"`
	Title     string    `json:"title"`
	Labels    []string  `json:"labels"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	Body      string    `json:"body"`
}

// PR is one recently merged GitHub pull request.
type PR struct {
	Number        int       `json:"number"`
	Title         string    `json:"title"`
	MergedAt      time.Time `json:"merged_at"`
	Files         []string  `json:"files"`
	Body          string    `json:"body"`
	DiffPath      string    `json:"diff_path,omitempty"`
	DiffSizeBytes int64     `json:"diff_size_bytes,omitempty"`
}

// TODO is one in-source marker comment (TODO/FIXME/HACK/XXX).
type TODO struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Marker  string `json:"marker"`
	Text    string `json:"text"`
	AgeDays int    `json:"age_days"`
}

// Deprecation is one in-source deprecation marker.
type Deprecation struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Kind    string `json:"kind"`
	Symbol  string `json:"symbol"`
	Message string `json:"message"`
}

// ADR is one architecture decision record under docs/adr/.
type ADR struct {
	File   string `json:"file"`
	Title  string `json:"title"`
	Status string `json:"status"`
	Body   string `json:"body"`
}

// RuleText is one CLAUDE.md file's contents.
type RuleText struct {
	File  string `json:"file"`
	Scope string `json:"scope"`
	Body  string `json:"body"`
}
