package render

import (
	"fmt"
	"sort"
	"strings"
)

// Pair renders a pair-shape row: two endpoints (left, right) plus optional
// paired companion fields with left_<X>/right_<X> prefixes.
func Pair(r Row) (string, error) {
	cid, _ := r["cluster_id"].(string)
	if cid == "" {
		return "", fmt.Errorf("pair: row missing cluster_id")
	}
	left, ok := r["left"].(map[string]any)
	if !ok {
		return "", fmt.Errorf("pair: row %q missing left{}", cid)
	}
	right, ok := r["right"].(map[string]any)
	if !ok {
		return "", fmt.Errorf("pair: row %q missing right{}", cid)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "### %s\n\n", cid)
	if hdr := pairHeaderSummary(r); hdr != "" {
		fmt.Fprintf(&b, "%s\n\n", hdr)
	}
	fmt.Fprintf(&b, "- left:  %s\n", renderMember(left))
	fmt.Fprintf(&b, "- right: %s\n", renderMember(right))
	if comp := pairCompanionBlock(r); comp != "" {
		fmt.Fprintf(&b, "\n%s", comp)
	}
	return b.String(), nil
}

// pairHeaderSummary builds the header line from well-known payload fields
// (jacc%, intersection, union, overlap, slot_diff_count, etc.).
func pairHeaderSummary(r Row) string {
	var parts []string
	if jv, ok := r["jacc"]; ok {
		if f, ok := numericFloat(jv); ok {
			parts = append(parts, fmt.Sprintf("jacc=%d%%", int(f*100)))
		}
	}
	for _, key := range pairHeaderKeys {
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

// pairHeaderKeys is the ordered allow-list of payload fields surfaced on the
// pair header (after jacc, which is special-cased to percent form).
var pairHeaderKeys = []string{
	"intersection",
	"union",
	"overlap",
	"slot_diff_count",
}

// pairCompanionBlock produces an aligned key-pair block for every left_<X>
// field that has a matching right_<X>. The block looks like:
//
//	- left fields:   a, b, c
//	- right fields:  a, b, d
//
// Label spelling: underscores in <X> render as spaces ("left_swap_tokens" →
// "left swap tokens"). Width is padded so the colon column aligns within the
// block.
func pairCompanionBlock(r Row) string {
	type pair struct {
		label string // "fields", "only", "slots", "swap_tokens", ...
		left  any
		right any
	}
	var pairs []pair
	leftKeys := make(map[string]any)
	for _, k := range sortedKeys(r) {
		if strings.HasPrefix(k, "left_") {
			leftKeys[strings.TrimPrefix(k, "left_")] = r[k]
		}
	}
	for _, k := range sortedKeys(r) {
		if !strings.HasPrefix(k, "right_") {
			continue
		}
		label := strings.TrimPrefix(k, "right_")
		if lv, ok := leftKeys[label]; ok {
			pairs = append(pairs, pair{label: label, left: lv, right: r[k]})
		}
	}
	if len(pairs) == 0 {
		return ""
	}
	// Stable order across the pair block: sort alphabetically by label.
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].label < pairs[j].label })

	widest := 0
	for _, p := range pairs {
		if w := len("right " + spaced(p.label)); w > widest {
			widest = w
		}
	}
	var b strings.Builder
	for _, p := range pairs {
		llabel := pad("left "+spaced(p.label)+":", widest+1)
		rlabel := pad("right "+spaced(p.label)+":", widest+1)
		fmt.Fprintf(&b, "- %s%s\n", llabel, formatList(p.left))
		fmt.Fprintf(&b, "- %s%s\n", rlabel, formatList(p.right))
	}
	return b.String()
}

// spaced replaces underscores with spaces for human-readable labels.
func spaced(s string) string { return strings.ReplaceAll(s, "_", " ") }

// pad right-pads s with spaces so the returned string is at least one
// character wider than n: if len(s) < n, the result is exactly n+1 long;
// if len(s) >= n, a single trailing space is appended. Call sites pass
// widest+1 as n to leave a one-space gutter beyond the widest label.
func pad(s string, n int) string {
	if len(s) >= n {
		return s + " "
	}
	return s + strings.Repeat(" ", n-len(s)+1)
}

// formatList renders a JSON-decoded array as a comma-joined string; non-array
// values fall back to JSON-ish formatting.
func formatList(v any) string {
	arr, ok := v.([]any)
	if !ok {
		return fmt.Sprintf("%v", v)
	}
	parts := make([]string, 0, len(arr))
	for _, item := range arr {
		switch s := item.(type) {
		case string:
			parts = append(parts, s)
		default:
			parts = append(parts, fmt.Sprintf("%v", s))
		}
	}
	return strings.Join(parts, ", ")
}

func numericFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}
