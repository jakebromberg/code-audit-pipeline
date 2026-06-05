package render

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Cluster renders a cluster-shape row: N members grouped by a common key.
// Single-member rows (orphan-infer-model, generic-convention-bound) are still
// cluster-shape — the envelope wraps the single decl as members[] of length 1.
func Cluster(r Row) (string, error) {
	cid, _ := r["cluster_id"].(string)
	if cid == "" {
		return "", fmt.Errorf("cluster: row missing cluster_id")
	}
	rawMembers, ok := r["members"].([]any)
	if !ok {
		return "", fmt.Errorf("cluster: row %q missing members[]", cid)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "### %s\n\n", cid)
	if hdr := clusterHeaderSummary(r, len(rawMembers)); hdr != "" {
		fmt.Fprintf(&b, "%s\n\n", hdr)
	}
	for _, m := range rawMembers {
		mm, ok := m.(map[string]any)
		if !ok {
			continue
		}
		fmt.Fprintf(&b, "- %s\n", renderMember(mm))
	}
	return b.String(), nil
}

// clusterHeaderSummary builds the "N decl(s), field_count=K, body_line_count=K"
// line. Whichever well-known payload fields are present and non-zero get
// joined. Member count is always shown.
func clusterHeaderSummary(r Row, memberCount int) string {
	parts := []string{fmt.Sprintf("%d decl(s)", memberCount)}
	for _, key := range clusterHeaderKeys {
		v, ok := r[key]
		if !ok {
			continue
		}
		if s := formatHeaderValue(key, v); s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, ", ")
}

// clusterHeaderKeys is the ordered allow-list of payload fields surfaced in
// the cluster header line. Order matches expected human reading order.
var clusterHeaderKeys = []string{
	"field_count",
	"body_line_count",
	"shape_sig",
	"body_hash",
	"base_name",
	"shapes_match",
	"shapes_observed",
	"mark_count",
	"line_count",
	"demoted",
	"wraps_notification_name",
}

// formatHeaderValue renders one payload field for the header line. body_hash
// is truncated to the first 8 chars; numerics render as integers when whole.
func formatHeaderValue(key string, v any) string {
	switch key {
	case "body_hash":
		s, ok := v.(string)
		if !ok || s == "" {
			return ""
		}
		if len(s) > 8 {
			s = s[:8]
		}
		return "body_hash=" + s
	case "shape_sig":
		s, _ := v.(string)
		if s == "" {
			return ""
		}
		return "shape_sig=" + s
	case "base_name":
		s, _ := v.(string)
		if s == "" {
			return ""
		}
		return "base_name=" + s
	case "shapes_match", "shapes_observed":
		b, ok := v.(bool)
		if !ok {
			return ""
		}
		if b {
			return key + "=true"
		}
		return key + "=false"
	case "demoted":
		// Only surface when true. The jq queries (exact-duplicates,
		// name-collisions, near-duplicates) emit `demoted: false` on every
		// non-demoted cluster — the 90% case — and rendering `demoted=false`
		// on every header would clutter the markdown report with noise. When
		// true, the cluster is already-abstracted and the operator needs to
		// see that signal prominently; mirror the jq text mode which only
		// prefixes "[DEMOTED — already abstracted]" for the true case.
		b, ok := v.(bool)
		if !ok || !b {
			return ""
		}
		return "demoted=true"
	case "wraps_notification_name":
		// Collapse internal whitespace so a multi-line getter body
		// (`{ Notification.Name(\n        "x"\n    ) }`) doesn't break the
		// comma-separated header line. The extractor preserves trivia in
		// trimmedDescription; the renderer is the natural place to normalize
		// because the same value also flows into the JSONL where preserving
		// the original formatting may matter for downstream comparison.
		s, _ := v.(string)
		if s == "" {
			return ""
		}
		// Replace any run of whitespace (incl. newlines, tabs) with a single
		// space, then trim.
		s = strings.Join(strings.Fields(s), " ")
		return "wraps_notification_name=" + s
	default:
		if n, ok := numericInt(v); ok {
			return fmt.Sprintf("%s=%d", key, n)
		}
		return fmt.Sprintf("%s=%v", key, v)
	}
}

// renderMember produces one bulleted member line. Format:
//
//	[*| ] <name> (<kind>) — <package>:<file>:<line>
//
// with optional inline annotations from a small allow-list of payload fields
// queries put on member objects (async, param_count). The leading marker is
// `*` for touched_in_window, single space otherwise so columns align across
// members.
func renderMember(m map[string]any) string {
	mark := " "
	if t, _ := m["touched_in_window"].(bool); t {
		mark = "*"
	}
	name, _ := m["name"].(string)
	kind, _ := m["kind"].(string)
	pkg, _ := m["package"].(string)
	file, _ := m["file"].(string)
	line, _ := numericInt(m["line"])

	var kindParts []string
	if kind != "" {
		kindParts = append(kindParts, kind)
	}
	for _, k := range memberInlineKeys {
		if v, ok := m[k]; ok {
			if s := formatMemberInline(k, v); s != "" {
				kindParts = append(kindParts, s)
			}
		}
	}
	kindBlock := ""
	if len(kindParts) > 0 {
		kindBlock = " (" + strings.Join(kindParts, ", ") + ")"
	}
	loc := pkg
	if file != "" {
		if loc != "" {
			loc += ":"
		}
		loc += file
	}
	if line > 0 {
		loc += fmt.Sprintf(":%d", line)
	}
	if loc == "" {
		return fmt.Sprintf("%s %s%s", mark, name, kindBlock)
	}
	return fmt.Sprintf("%s %s%s — %s", mark, name, kindBlock, loc)
}

// memberInlineKeys is the allow-list of member-object payload fields surfaced
// inline after the kind. Order matters for stable rendering.
var memberInlineKeys = []string{
	"async",
	"param_count",
	"version",
}

func formatMemberInline(key string, v any) string {
	switch key {
	case "async":
		if b, ok := v.(bool); ok && b {
			return "async"
		}
		return ""
	case "param_count":
		if n, ok := numericInt(v); ok {
			return fmt.Sprintf("arity=%d", n)
		}
		return ""
	case "version":
		// versioned-type-pairs members carry version >= 0. Omit when zero
		// (the unversioned baseline) to keep the line short; a `v=N` annotation
		// only surfaces when the member is an explicit version.
		if n, ok := numericInt(v); ok && n > 0 {
			return fmt.Sprintf("v=%d", n)
		}
		return ""
	}
	return ""
}

// numericInt extracts an integer from a JSON-decoded value. encoding/json
// decodes numbers as float64; we round to nearest int for display.
func numericInt(v any) (int, bool) {
	switch n := v.(type) {
	case float64:
		return int(n), true
	case int:
		return n, true
	case int64:
		return int(n), true
	case json.Number:
		i, err := n.Int64()
		if err == nil {
			return int(i), true
		}
	}
	return 0, false
}

// sortedKeys is shared utility — produces deterministic ordering for any
// map-keyed iteration in the package.
func sortedKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
