package main

import (
	"embed"
	"io/fs"
)

//go:generate go run ../../internal/genqueries -src ../../pipeline/queries -dst ./queries

//go:embed queries/*.jq
//go:embed queries/_canonical.jq
var embeddedQueriesRoot embed.FS

// embeddedQueries returns an fs.FS rooted at the queries/ subdirectory so
// callers see _canonical.jq and *.jq at the top level (matching how a
// filesystem queries directory looks).
func embeddedQueries() fs.FS {
	sub, err := fs.Sub(embeddedQueriesRoot, "queries")
	if err != nil {
		panic("audit: embedded queries subroot: " + err.Error())
	}
	return sub
}
