// Package render produces markdown blocks from JSONL cluster-envelope rows.
// Each row carries `shape: "cluster" | "pair" | "metric"` per ADR-0003; Dispatch
// picks the renderer from a single table keyed on shape, never on the query.
//
// A renderer consumes one parsed row (the result of json.Unmarshal into a
// map[string]any) and returns a markdown string. The report driver
// (internal/cli/report.go) concatenates rows under one section header per
// query.
package render

import (
	"fmt"
)

// Row is one parsed JSONL line. All envelope and payload fields live here.
type Row map[string]any

// Renderer turns one row into a markdown block.
type Renderer func(r Row) (string, error)

var byShape = map[string]Renderer{
	"cluster": Cluster,
	"pair":    Pair,
	"metric":  Metric,
}

// Dispatch returns the markdown for one row, selecting the renderer from the
// row's shape field. An unknown or missing shape is a hard error — every query
// is required to declare its shape via front-matter, and every row carries it
// per the cluster envelope contract.
func Dispatch(r Row) (string, error) {
	s, ok := r["shape"].(string)
	if !ok || s == "" {
		return "", fmt.Errorf("render: row missing shape field (cluster_id=%v)", r["cluster_id"])
	}
	fn, ok := byShape[s]
	if !ok {
		return "", fmt.Errorf("render: unknown shape %q (cluster_id=%v)", s, r["cluster_id"])
	}
	return fn(r)
}
