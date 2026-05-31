package diffmatch

import "sort"

// FunctionRow is the subset of function-catalog fields find-next-instance
// joins against. Decoded from the catalog's `entries[]`.
type FunctionRow struct {
	Name          string   `json:"name"`
	Kind          string   `json:"kind"`
	Package       string   `json:"package"`
	File          string   `json:"file"`
	Line          int      `json:"line"`
	BodyHash      *string  `json:"body_hash"`
	BodyLines     []string `json:"body_lines"`
	BodyLineCount *int     `json:"body_line_count"`
	Generated     bool     `json:"generated"`
	IsTest        bool     `json:"is_test"`
}

// TypeRow is the subset of type-catalog fields find-next-instance joins
// against.
type TypeRow struct {
	Name             string                 `json:"name"`
	Kind             string                 `json:"kind"`
	Package          string                 `json:"package"`
	File             string                 `json:"file"`
	Line             int                    `json:"line"`
	Fields           []string               `json:"fields"`
	FieldsStructured []FieldStructured      `json:"fields_structured"`
	Generated        bool                   `json:"generated"`
	IsTest           bool                   `json:"is_test"`
	Extra            map[string]interface{} `json:"-"`
}

// FieldStructured mirrors the V7 §6.1 sub-row shape.
type FieldStructured struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	IsOptional bool   `json:"is_optional"`
	IsStatic   bool   `json:"is_static"`
}

// FunctionMatch is one candidate function-catalog entry whose body_lines
// contain the removed-line set (or a high-Jaccard fraction of it).
type FunctionMatch struct {
	Row          FunctionRow
	Intersection int
	Union        int
	Jaccard      float64
}

// FunctionBodyMatches returns every catalog row whose normalized body_lines
// share at least minIntersection lines with removedNorm AND whose Jaccard
// score against removedNorm meets minJaccard. removedNorm must already be
// sorted-unique (the output of Normalize / NormalizeText).
//
// Self-match suppression: rows whose (file, line) equal the diff source
// site are excluded — the matcher reports candidates *other than* the PR's
// own edit point. The skipFile / skipLine pair is used for that filter;
// pass empty / 0 to disable.
func FunctionBodyMatches(rows []FunctionRow, removedNorm []string, minIntersection int, minJaccard float64, skipFile string, skipLine int) []FunctionMatch {
	if len(removedNorm) == 0 {
		return nil
	}
	rset := indexLines(removedNorm)
	var out []FunctionMatch
	for _, r := range rows {
		if r.BodyHash == nil || len(r.BodyLines) == 0 {
			continue
		}
		if r.File == skipFile && r.Line == skipLine {
			continue
		}
		bset := indexLines(r.BodyLines)
		inter := setIntersectionSize(rset, bset)
		if inter < minIntersection {
			continue
		}
		union := len(rset) + len(bset) - inter
		if union == 0 {
			continue
		}
		jacc := float64(inter) / float64(union)
		if jacc < minJaccard {
			continue
		}
		out = append(out, FunctionMatch{
			Row:          r,
			Intersection: inter,
			Union:        union,
			Jaccard:      jacc,
		})
	}
	// Stable ranking: best score first, then by location for determinism.
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Jaccard != out[j].Jaccard {
			return out[i].Jaccard > out[j].Jaccard
		}
		if out[i].Row.Package != out[j].Row.Package {
			return out[i].Row.Package < out[j].Row.Package
		}
		if out[i].Row.File != out[j].Row.File {
			return out[i].Row.File < out[j].Row.File
		}
		return out[i].Row.Line < out[j].Row.Line
	})
	return out
}

// TypeShapeMatch is one type-catalog entry whose field-name set contains the
// removed-field name set.
type TypeShapeMatch struct {
	Row          TypeRow
	Intersection int
	Union        int
	Jaccard      float64
}

// TypeShapeMatches returns every catalog row whose field-name set contains
// every name in removedFields, ranked by Jaccard score. removedFields is
// treated as a set (duplicates collapsed).
//
// Same self-match filter as FunctionBodyMatches: rows at (skipFile, skipLine)
// are excluded.
func TypeShapeMatches(rows []TypeRow, removedFields []string, minIntersection int, minJaccard float64, skipFile string, skipLine int) []TypeShapeMatch {
	if len(removedFields) == 0 {
		return nil
	}
	rset := indexLines(removedFields)
	var out []TypeShapeMatch
	for _, r := range rows {
		if r.File == skipFile && r.Line == skipLine {
			continue
		}
		names := typeFieldNames(r)
		if len(names) == 0 {
			continue
		}
		bset := indexLines(names)
		inter := setIntersectionSize(rset, bset)
		if inter < minIntersection {
			continue
		}
		// "Subset" semantics: every removed field appears in the candidate.
		if inter < len(rset) {
			continue
		}
		union := len(rset) + len(bset) - inter
		if union == 0 {
			continue
		}
		jacc := float64(inter) / float64(union)
		if jacc < minJaccard {
			continue
		}
		out = append(out, TypeShapeMatch{
			Row:          r,
			Intersection: inter,
			Union:        union,
			Jaccard:      jacc,
		})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Jaccard != out[j].Jaccard {
			return out[i].Jaccard > out[j].Jaccard
		}
		if out[i].Row.Package != out[j].Row.Package {
			return out[i].Row.Package < out[j].Row.Package
		}
		if out[i].Row.File != out[j].Row.File {
			return out[i].Row.File < out[j].Row.File
		}
		return out[i].Row.Line < out[j].Row.Line
	})
	return out
}

// typeFieldNames returns the set of field names on a type-catalog row,
// preferring `fields_structured` (V7 §6.1) and falling back to splitting
// `fields[]` entries on the first ':' (with the trailing '?' stripped).
func typeFieldNames(r TypeRow) []string {
	if len(r.FieldsStructured) > 0 {
		out := make([]string, len(r.FieldsStructured))
		for i, f := range r.FieldsStructured {
			out[i] = f.Name
		}
		return out
	}
	if len(r.Fields) == 0 {
		return nil
	}
	out := make([]string, 0, len(r.Fields))
	for _, f := range r.Fields {
		name := f
		if i := indexByte(name, ':'); i >= 0 {
			name = name[:i]
		}
		// Strip trailing optional marker.
		if n := len(name); n > 0 && name[n-1] == '?' {
			name = name[:n-1]
		}
		if name != "" {
			out = append(out, name)
		}
	}
	return out
}

func indexLines(lines []string) map[string]struct{} {
	m := make(map[string]struct{}, len(lines))
	for _, l := range lines {
		m[l] = struct{}{}
	}
	return m
}

func setIntersectionSize(a, b map[string]struct{}) int {
	// Iterate the smaller map for the membership probe.
	small, large := a, b
	if len(b) < len(a) {
		small, large = b, a
	}
	n := 0
	for k := range small {
		if _, ok := large[k]; ok {
			n++
		}
	}
	return n
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
