package diffmatch

import (
	"regexp"
	"sort"
	"strings"
)

// fieldDecl matches the heads of Swift and TypeScript field declarations on
// a *normalized* line (already trimmed, single-spaced, comments removed):
//
//   Swift:  [public|private|fileprivate|internal|static|var|let|class]* (var|let) NAME (: TYPE)? …
//   TS:     NAME(?)? : TYPE (;|,)?
//
// The grammar is intentionally lenient — we want to recover the field NAME
// from removed diff lines that look field-shaped. False positives don't
// silently corrupt: TypeShapeMatches requires the full set to be a subset of
// a real catalog row's field names, so non-field strings that sneak through
// here simply fail the subset test.
var (
	swiftField = regexp.MustCompile(`^(?:(?:public|private|fileprivate|internal|open|package|static|class|final|weak|unowned|lazy|@?\w+|override)\s+)*(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\b`)
	tsField    = regexp.MustCompile(`^(?:(?:public|private|protected|readonly|static)\s+)*([A-Za-z_$][A-Za-z0-9_$]*)\??\s*:\s*\S`)
)

// ExtractRemovedFieldNames scans the removed lines of a hunk for ones that
// look like field declarations and returns the deduped set of declared
// names. The lines are first run through NormalizeText so callers don't need
// to pre-normalize.
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
	// Bare-name shorthand for interface/struct fields without an explicit
	// modifier prefix (e.g., "id: number" with no `let`/`var`). Re-try the
	// Swift pattern with a synthetic `var ` prefix to catch struct stored
	// properties whose modifier list happened to be empty AND the var/let
	// got elided. We don't do this — those lines should be matched by the
	// tsField regex if they have a type clause, or they aren't fields.
	if strings.Contains(line, ":") {
		head := strings.TrimSpace(strings.SplitN(line, ":", 2)[0])
		// Strip a trailing '?' optionality marker.
		head = strings.TrimSuffix(head, "?")
		if head != "" && validIdent(head) {
			return head
		}
	}
	return ""
}

func validIdent(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		switch {
		case r == '_' || r == '$':
			// allowed
		case r >= 'A' && r <= 'Z':
		case r >= 'a' && r <= 'z':
		case i > 0 && r >= '0' && r <= '9':
		default:
			return false
		}
	}
	return true
}
