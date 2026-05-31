package diffmatch

import (
	"regexp"
	"sort"
)

// Field-declaration regexes match removed diff lines that carry a NAME and
// an explicit `: TYPE` clause. Both anchors require a leading type-token
// after the colon — that's what distinguishes a real field decl from a
// switch-case label (`default:`), Go label, dict key, or local assignment
// without a type annotation.
//
//   Swift:  [modifiers]* (var|let) NAME : TYPE …
//   TS:     [modifiers]* NAME ? : TYPE …      (where TYPE starts with an ident)
var (
	swiftField = regexp.MustCompile(`^(?:(?:public|private|fileprivate|internal|open|package|static|class|final|weak|unowned|lazy|@?\w+|override)\s+)*(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[A-Za-z_(\[]`)
	tsField    = regexp.MustCompile(`^(?:(?:public|private|protected|readonly|static)\s+)*([A-Za-z_$][A-Za-z0-9_$]*)\??\s*:\s*[A-Za-z_$(\[{'"]`)
)

// ExtractRemovedFieldNames scans the removed lines of a hunk for ones that
// look like field declarations and returns the deduped set of declared
// names. The lines are first run through NormalizeText so callers don't need
// to pre-normalize.
//
// Lines without an explicit `: TYPE` clause are rejected — that filters out
// switch-case labels (`default:`), Go/Swift loop labels, dictionary keys,
// and local assignments (`let x = 1`) that would otherwise pollute the
// removed-field set.
func ExtractRemovedFieldNames(removed []string) []string {
	if len(removed) == 0 {
		return nil
	}
	norm := Normalize(removed)
	seen := make(map[string]struct{}, len(norm))
	for _, l := range norm {
		if name := matchFieldName(l); name != "" {
			seen[name] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func matchFieldName(line string) string {
	if m := swiftField.FindStringSubmatch(line); m != nil {
		return m[1]
	}
	if m := tsField.FindStringSubmatch(line); m != nil {
		return m[1]
	}
	return ""
}
