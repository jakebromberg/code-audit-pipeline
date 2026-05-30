package render

import (
	"encoding/json"
	"fmt"
	"strings"
)

// envelopeKeys is the set of fields reserved by the cluster envelope contract
// (cluster_id, query, shape, members, left, right plus left_/right_ prefixed
// companion variants). Metric rendering skips these in the payload list.
var envelopeKeys = map[string]bool{
	"cluster_id": true,
	"query":      true,
	"shape":      true,
	"members":    true,
	"left":       true,
	"right":      true,
}

// Metric renders a metric-shape row: a payload key-value list, plus nested
// cluster blocks for any array-of-cluster-shaped-objects payload field
// (touched-window-debt-summary's touched_clusters[]).
func Metric(r Row) (string, error) {
	cid, _ := r["cluster_id"].(string)
	if cid == "" {
		return "", fmt.Errorf("metric: row missing cluster_id")
	}

	var b strings.Builder
	fmt.Fprintf(&b, "### %s\n\n", cid)

	var nested []nestedClusters
	for _, k := range sortedKeys(r) {
		if envelopeKeys[k] || strings.HasPrefix(k, "left_") || strings.HasPrefix(k, "right_") {
			continue
		}
		v := r[k]
		if clusters, ok := asNestedClusters(v); ok {
			nested = append(nested, nestedClusters{label: k, rows: clusters})
			continue
		}
		fmt.Fprintf(&b, "- %s: %s\n", k, formatScalar(v))
	}

	for _, nc := range nested {
		fmt.Fprintf(&b, "\n#### %s\n\n", humanizeLabel(nc.label))
		if len(nc.rows) == 0 {
			b.WriteString("_none_\n")
			continue
		}
		for _, c := range nc.rows {
			block, err := Cluster(c)
			if err != nil {
				return "", fmt.Errorf("metric: nested cluster in %q: %w", nc.label, err)
			}
			block = strings.ReplaceAll(block, "### ", "##### ")
			b.WriteString(block)
		}
	}
	return b.String(), nil
}

type nestedClusters struct {
	label string
	rows  []Row
}

// asNestedClusters detects a JSON array whose every element is an object
// carrying cluster_id and members[] — the signature of the cluster envelope.
// Used so a metric query like touched-window-debt-summary can nest source
// clusters under its summary without the renderer needing to know the query.
func asNestedClusters(v any) ([]Row, bool) {
	arr, ok := v.([]any)
	if !ok || len(arr) == 0 {
		return nil, false
	}
	out := make([]Row, 0, len(arr))
	for _, item := range arr {
		mm, ok := item.(map[string]any)
		if !ok {
			return nil, false
		}
		if _, ok := mm["cluster_id"].(string); !ok {
			return nil, false
		}
		if _, ok := mm["members"].([]any); !ok {
			return nil, false
		}
		// Nested clusters won't carry their own shape:"cluster" reliably
		// (touched-window-debt-summary's nested objects only carry
		// cluster_id + members), so we inject it for the recursive call.
		row := Row(mm)
		if _, hasShape := row["shape"]; !hasShape {
			row["shape"] = "cluster"
		}
		out = append(out, row)
	}
	return out, true
}

// formatScalar produces a one-line string for a JSON-decoded value. Objects
// and arrays serialize to compact JSON so the metric row stays readable on a
// single line; strings render as-is; numbers as their JSON form.
func formatScalar(v any) string {
	switch n := v.(type) {
	case string:
		return n
	case bool:
		if n {
			return "true"
		}
		return "false"
	case float64:
		if n == float64(int64(n)) {
			return fmt.Sprintf("%d", int64(n))
		}
		return fmt.Sprintf("%g", n)
	case json.Number:
		return n.String()
	}
	data, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(data)
}

// humanizeLabel converts snake_case to space-separated Title Case for the
// nested-block sub-heading.
func humanizeLabel(s string) string {
	parts := strings.Split(s, "_")
	for i, p := range parts {
		if p == "" {
			continue
		}
		parts[i] = strings.ToUpper(p[:1]) + p[1:]
	}
	return strings.Join(parts, " ")
}
