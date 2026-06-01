package main

import (
	"embed"
	"io/fs"
)

//go:generate go run ../../internal/genembed -src ../../pipeline/queries -dst ./queries -flatten -ext .jq

//go:generate go run ../../internal/genembed -src ../../extractors -dst ./extractors -skip node_modules,.build,.swiftpm,DerivedData,Pods,dist,build,coverage

//go:embed queries/*.jq
//go:embed queries/_canonical.jq
var embeddedQueriesRoot embed.FS

// embeddedExtractorsRoot bundles extractor source into the binary so a
// future change (see issue #241, PR β) can populate
// ~/.config/audit/extractors/ on a fresh brew install with no checkout
// required. This PR α ships the embed pipeline but does not yet consume
// it — the auto-extract gate that reads from embeddedExtractors() lands
// in PR β.
//
//go:embed extractors
var embeddedExtractorsRoot embed.FS

// embeddedQueries returns an fs.FS rooted at the queries/ subdirectory so
// callers see _canonical.jq and *.jq at the top level (matching how a
// filesystem queries directory looks).
func embeddedQueries() fs.FS {
	sub, err := fs.Sub(embeddedQueriesRoot, "queries")
	if err != nil {
		panic("code-audit: embedded queries subroot: " + err.Error())
	}
	return sub
}

// embeddedExtractors returns an fs.FS rooted at the extractors/
// subdirectory so callers see <language>/ at the top level (matching the
// source tree under repo-root/extractors/).
//
// Currently unused by any caller in PR α — see embeddedExtractorsRoot's
// comment. Kept declared so PR β can wire it into the auto-extract path
// without an additional accessor.
func embeddedExtractors() fs.FS {
	sub, err := fs.Sub(embeddedExtractorsRoot, "extractors")
	if err != nil {
		panic("code-audit: embedded extractors subroot: " + err.Error())
	}
	return sub
}

// Reference embeddedExtractors so `go vet` does not flag it as unused in
// PR α. PR β replaces this reference with a real call site.
var _ = embeddedExtractors
