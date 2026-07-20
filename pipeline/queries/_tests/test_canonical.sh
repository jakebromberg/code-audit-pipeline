#!/usr/bin/env bash
# Tests for _canonical.jq's cluster_id helpers and output-mode behavior.
#
# Run from repo root: pipeline/queries/_tests/test_canonical.sh
# Exits 0 on success; non-zero on any assertion failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  ✗ %s\n     expected: %s\n     actual:   %s\n" "$desc" "$expected" "$actual"
  fi
}

run() {
  local jq_expr="$1"
  echo '{}' | jq -L "$QUERIES_DIR" -r "include \"_canonical\"; $jq_expr"
}

run_env() {
  local env_var="$1"
  local jq_expr="$2"
  echo '{}' | env "$env_var" jq -L "$QUERIES_DIR" -r "include \"_canonical\"; $jq_expr"
}

echo "=== cluster_id_sorted_names ==="
assert_eq "sorts ['B','A','C'] alphabetically" \
  "exact-duplicates:A+B+C" \
  "$(run 'cluster_id_sorted_names("exact-duplicates"; ["B", "A", "C"])')"

assert_eq "single-name input emits prefix:Name" \
  "exact-duplicates:OnlyOne" \
  "$(run 'cluster_id_sorted_names("exact-duplicates"; ["OnlyOne"])')"

assert_eq "handles names with special chars literally" \
  "function-duplicates-exact:Foo+Foo_v2" \
  "$(run 'cluster_id_sorted_names("function-duplicates-exact"; ["Foo_v2", "Foo"])')"

echo "=== cluster_id_single_name ==="
assert_eq "emits prefix:Name" \
  "name-collisions:RadioStation" \
  "$(run 'cluster_id_single_name("name-collisions"; "RadioStation")')"

echo "=== cluster_id_sorted_pair ==="
assert_eq "sorts pair regardless of input order — (B, A)" \
  "near-duplicates:A+B" \
  "$(run 'cluster_id_sorted_pair("near-duplicates"; "B"; "A")')"

assert_eq "sorts pair — (A, B)" \
  "near-duplicates:A+B" \
  "$(run 'cluster_id_sorted_pair("near-duplicates"; "A"; "B")')"

assert_eq "different prefixes for -any variants" \
  "near-duplicates-any:Foo+Goo" \
  "$(run 'cluster_id_sorted_pair("near-duplicates-any"; "Foo"; "Goo")')"

echo "=== cluster_id_directed_pair ==="
assert_eq "preserves direction — Sub__Sup" \
  "subset-pairs:Sub__Sup" \
  "$(run 'cluster_id_directed_pair("subset-pairs"; "Sub"; "Sup")')"

assert_eq "swapped direction yields different id" \
  "subset-pairs:Sup__Sub" \
  "$(run 'cluster_id_directed_pair("subset-pairs"; "Sup"; "Sub")')"

echo "=== cluster_id_sorted_paths ==="
assert_eq "sorts repo-relative paths" \
  "file-duplicates-exact:Shared/A.swift+Shared/B.swift" \
  "$(run 'cluster_id_sorted_paths("file-duplicates-exact"; ["Shared/B.swift", "Shared/A.swift"])')"

echo "=== loc_key ==="
assert_eq "concatenates package:file:line:name" \
  "Shared/Core:Sources/Core/Foo.swift:42:hashSlug" \
  "$(run 'loc_key({package: "Shared/Core", file: "Sources/Core/Foo.swift", line: 42, name: "hashSlug"})')"

assert_eq "fn_location_key alias produces identical output" \
  "Shared/Core:Sources/Core/Foo.swift:42:hashSlug" \
  "$(run 'fn_location_key({package: "Shared/Core", file: "Sources/Core/Foo.swift", line: 42, name: "hashSlug"})')"

echo "=== type_of (qualified-name → enclosing-type) ==="
assert_eq "Foo.bar drops .bar, returns Foo" \
  "Foo" \
  "$(run 'type_of("Foo.bar")')"

assert_eq "Foo.Bar.baz drops .baz, returns Foo.Bar (nested type)" \
  "Foo.Bar" \
  "$(run 'type_of("Foo.Bar.baz")')"

assert_eq "free function (no dot) is unchanged" \
  "freeFunction" \
  "$(run 'type_of("freeFunction")')"

assert_eq "empty input returns empty" \
  "" \
  "$(run 'type_of("")')"

echo "=== tokens_of (identifier extraction) ==="
assert_eq "simple identifier line yields its tokens" \
  '["return","UIColor","red"]' \
  "$(run '"return UIColor.red" | tokens_of | tojson')"

assert_eq "multi-char separators don't produce empty tokens" \
  '["return","foo","bar"]' \
  "$(run '"return  foo,, bar;" | tokens_of | tojson')"

assert_eq "underscores and digits stay inside tokens" \
  '["my_var_2","x3"]' \
  "$(run '"my_var_2 + x3" | tokens_of | tojson')"

assert_eq "ASCII-only: Greek identifier (π) elided" \
  '["let","x"]' \
  "$(run '"let π = x" | tokens_of | tojson')"

assert_eq "ASCII-only: emoji elided as separator" \
  '["a","b"]' \
  "$(run '"a 🎉 b" | tokens_of | tojson')"

assert_eq "ASCII-only: RTL Hebrew elided" \
  '["world"]' \
  "$(run '"שלום world" | tokens_of | tojson')"

assert_eq "empty input yields empty list" \
  '[]' \
  "$(run '"" | tokens_of | tojson')"

echo "=== is_published (cross-repo filter helper, #155) ==="
assert_eq "true when origin_package is a non-empty string" \
  "true" \
  "$(echo '{"origin_package": "react"}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_published')"

assert_eq "true for scoped package names" \
  "true" \
  "$(echo '{"origin_package": "@wxyc/lml-client"}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_published')"

assert_eq "false when origin_package is null" \
  "false" \
  "$(echo '{"origin_package": null}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_published')"

assert_eq "false when origin_package field is absent" \
  "false" \
  "$(echo '{"kind": "type-alias", "name": "Foo"}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_published')"

assert_eq "false when origin_package is empty string" \
  "false" \
  "$(echo '{"origin_package": ""}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_published')"

echo "=== is_repo_local (complement of is_published) ==="
assert_eq "false when origin_package is set" \
  "false" \
  "$(echo '{"origin_package": "react"}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_repo_local')"

assert_eq "true when origin_package is null" \
  "true" \
  "$(echo '{"origin_package": null}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_repo_local')"

assert_eq "true when origin_package is absent" \
  "true" \
  "$(echo '{"kind": "type-alias"}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_repo_local')"

assert_eq "true when origin_package is empty string" \
  "true" \
  "$(echo '{"origin_package": ""}' | jq -L "$QUERIES_DIR" -r 'include "_canonical"; is_repo_local')"

echo "=== stale_threshold_days (env-overridable cutoff in days) ==="
assert_eq "default is 7 when env unset" \
  "7" \
  "$(run 'stale_threshold_days')"

assert_eq "honors CROSS_REPO_STALE_DAYS=14" \
  "14" \
  "$(run_env 'CROSS_REPO_STALE_DAYS=14' 'stale_threshold_days')"

assert_eq "honors CROSS_REPO_STALE_DAYS=30" \
  "30" \
  "$(run_env 'CROSS_REPO_STALE_DAYS=30' 'stale_threshold_days')"

echo "=== intersect_string_arrays ==="
assert_eq "empty input yields empty array" \
  '[]' \
  "$(run '[] | intersect_string_arrays | tojson')"

assert_eq "single input passes through unchanged" \
  '["a","b"]' \
  "$(run '[["a","b"]] | intersect_string_arrays | tojson')"

assert_eq "two arrays — common elements preserved in first-array order" \
  '["b","c"]' \
  "$(run '[["a","b","c"], ["b","c","d"]] | intersect_string_arrays | tojson')"

assert_eq "no overlap yields empty" \
  '[]' \
  "$(run '[["a","b"], ["c","d"]] | intersect_string_arrays | tojson')"

assert_eq "three arrays — only universal members survive" \
  '["b"]' \
  "$(run '[["a","b","c"], ["b","c","d"], ["b","e"]] | intersect_string_arrays | tojson')"

echo "=== protocols_index ==="
# Build a tiny synthetic catalog (bare-array v1.0 form, handled by `entries`).
# Two interface records sharing a name should merge their fields[]; a
# non-interface row should be ignored.
PROTOS_FIXTURE='[
  {"name":"MusicService","kind":"interface","fields":["fetch(id:String):Track","search(query:String):[Track]"]},
  {"name":"MusicService","kind":"interface","fields":["save(track:Track):Void"]},
  {"name":"Sendable","kind":"interface","fields":[]},
  {"name":"NotAProtocol","kind":"type-alias-object","fields":["a:Int","b:String"]}
]'

assert_eq "indexes by name; merges fields across same-name records" \
  '["fetch(id:String):Track","save(track:Track):Void","search(query:String):[Track]"]' \
  "$(echo "$PROTOS_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; protocols_index | .MusicService.fields | tojson')"

assert_eq "marker protocol with empty fields indexes to empty fields" \
  '[]' \
  "$(echo "$PROTOS_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; protocols_index | .Sendable.fields | tojson')"

assert_eq "non-interface kinds are excluded from the index" \
  'null' \
  "$(echo "$PROTOS_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; protocols_index | .NotAProtocol // null | tojson')"

echo "=== conformance_index ==="
# Swift declares conformance both inline (`struct Foo: P`) and retroactively
# via extensions (`extension Foo: P {}`) — separate catalog records sharing a
# name. The index merges conforms_to[] across all same-name records so a
# demotion check sees extension-declared conformances too.
CONF_FIXTURE='[
  {"name":"LiveFeed","kind":"type-alias-object","conforms_to":[]},
  {"name":"LiveFeed","kind":"extension","conforms_to":["FeedRepresentable","Sendable"]},
  {"name":"CachedFeed","kind":"type-alias-object","conforms_to":["FeedRepresentable"]},
  {"name":"Dup","kind":"type-alias-object","conforms_to":["P"]},
  {"name":"Dup","kind":"extension","conforms_to":["P","Q"]},
  {"name":"Plain","kind":"type-alias-object"},
  {"name":"Facade","kind":"type-alias-object","conforms_to":["Sendable"]},
  {"name":"Facade","kind":"interface","conforms_to":["Renderable"]},
  {"name":"PureProto","kind":"interface","conforms_to":["BaseProto"]}
]'

assert_eq "merges conforms_to across same-name records (decl + extension)" \
  '["FeedRepresentable","Sendable"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index | .LiveFeed | tojson')"

assert_eq "single-record name passes through unchanged" \
  '["FeedRepresentable"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index | .CachedFeed | tojson')"

assert_eq "duplicate protocol across decl + extension de-duplicates" \
  '["P","Q"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index | .Dup | tojson')"

assert_eq "record without conforms_to is absent from the index" \
  'null' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index | .Plain // null | tojson')"

# An interface's conforms_to is protocol INHERITANCE, not concrete
# conformance — merging it would credit a same-name concrete type with the
# protocol's parents and falsely demote pairs involving that type.
assert_eq "interface records' inheritance is NOT merged into a same-name type" \
  '["Sendable"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index | .Facade | tojson')"

assert_eq "a name declared only as an interface is absent from the index" \
  'null' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index | .PureProto // null | tojson')"

echo "=== with_conformance ==="
# Companion applied per decl when consuming conformance_index: unions the
# index lookup with the decl's own conforms_to, restoring the interface
# inheritance the index excludes.

assert_eq "interface decl restores its inheritance over the index lookup" \
  '["Renderable","Sendable"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index as $idx | {name:"Facade",kind:"interface",conforms_to:["Renderable"]} | with_conformance($idx) | .conforms_to | tojson')"

assert_eq "decl with empty conforms_to takes the merged index entry" \
  '["FeedRepresentable","Sendable"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index as $idx | {name:"LiveFeed",kind:"type-alias-object",conforms_to:[]} | with_conformance($idx) | .conforms_to | tojson')"

assert_eq "name absent from the index falls back to the decl's own conforms_to" \
  '["BaseProto"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index as $idx | {name:"PureProto",kind:"interface",conforms_to:["BaseProto"]} | with_conformance($idx) | .conforms_to | tojson')"

assert_eq "no index entry and no own conforms_to yields empty array" \
  '[]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index as $idx | {name:"Plain",kind:"type-alias-object"} | with_conformance($idx) | .conforms_to | tojson')"

assert_eq "index entry duplicating the decl's own conforms_to de-duplicates" \
  '["FeedRepresentable"]' \
  "$(echo "$CONF_FIXTURE" | jq -L "$QUERIES_DIR" -r 'include "_canonical"; conformance_index as $idx | {name:"CachedFeed",kind:"type-alias-object",conforms_to:["FeedRepresentable"]} | with_conformance($idx) | .conforms_to | tojson')"

echo "=== is_already_abstracted_cluster ==="
# Hand-crafted index: MusicService is a non-trivial protocol (3 fields);
# Sendable is a marker (0 fields).
IDX='{"MusicService":{"kind":"interface","fields":["fetch","save","search"]},"Sendable":{"kind":"interface","fields":[]}}'

assert_eq "cluster sharing a non-trivial protocol is demoted" \
  'true' \
  "$(run "[{\"conforms_to\":[\"MusicService\",\"Sendable\"]},{\"conforms_to\":[\"MusicService\"]},{\"conforms_to\":[\"MusicService\",\"Codable\"]}] | is_already_abstracted_cluster(${IDX})")"

assert_eq "cluster sharing only a marker (Sendable) is NOT demoted" \
  'false' \
  "$(run "[{\"conforms_to\":[\"Sendable\"]},{\"conforms_to\":[\"Sendable\"]}] | is_already_abstracted_cluster(${IDX})")"

assert_eq "cluster with no shared conformance is NOT demoted" \
  'false' \
  "$(run "[{\"conforms_to\":[\"A\"]},{\"conforms_to\":[\"B\"]}] | is_already_abstracted_cluster(${IDX})")"

assert_eq "pair (2-element array) sharing a real protocol is demoted (near-duplicates contract)" \
  'true' \
  "$(run "[{\"conforms_to\":[\"MusicService\"]},{\"conforms_to\":[\"MusicService\"]}] | is_already_abstracted_cluster(${IDX})")"

assert_eq "cluster where one member has no conforms_to is NOT demoted (intersection collapses)" \
  'false' \
  "$(run "[{\"conforms_to\":[\"MusicService\"]},{}] | is_already_abstracted_cluster(${IDX})")"

assert_eq "cluster sharing a name unknown to \$protocols_idx is NOT demoted" \
  'false' \
  "$(run "[{\"conforms_to\":[\"UnregisteredProto\"]},{\"conforms_to\":[\"UnregisteredProto\"]}] | is_already_abstracted_cluster(${IDX})")"

echo "=== output_format ==="
assert_eq "default is text" \
  "text" \
  "$(run 'output_format')"

assert_eq "OUTPUT_FORMAT=jsonl flips to jsonl" \
  "jsonl" \
  "$(run_env 'OUTPUT_FORMAT=jsonl' 'output_format')"

assert_eq "OUTPUT_FORMAT=text is explicit default" \
  "text" \
  "$(run_env 'OUTPUT_FORMAT=text' 'output_format')"

echo ""
echo "=== Results ==="
printf "Passed: %d\n" "$PASS"
printf "Failed: %d\n" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
