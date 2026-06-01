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

// embeddedExtractors returns an fs.FS rooted at the extractors/ subdirectory
// so callers see <language>/ at the top level (matching the source tree
// under repo-root/extractors/).
func embeddedExtractors() fs.FS {
	sub, err := fs.Sub(embeddedExtractorsRoot, "extractors")
	if err != nil {
		panic("code-audit: embedded extractors subroot: " + err.Error())
	}
	return sub
}
