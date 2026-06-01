# noop-query.jq — sentinel fixture for the run-cross-repo-query.sh wrapper
# tests. Emits a single marker line so the test can detect whether the
# query was actually invoked (vs. skipped due to preflight refusal).
#
# Run:  jq -L pipeline/queries -rf <this>.jq merged-input.json
#
#! query: noop
#! shape: metric
#! catalog: type-catalog
#! formats: text
#! desc: Test-only marker emitter.

"NOOP-MARKER"
