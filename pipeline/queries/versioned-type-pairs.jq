# versioned-type-pairs.jq — surface declarations sharing a base name after
# stripping a trailing `V?<n>` (or bare `<n>`) suffix. A common stalled-migration
# shape: the old type and the new type coexist (`Track` + `TrackV2`, `Episode` +
# `EpisodeV2`) because somebody started cutting callers over and paused. Each
# cluster is one (package, base_name) group with ≥ 2 distinct full names.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/versioned-type-pairs.jq catalog.json
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/versioned-type-pairs.jq catalog.json
#
# Optional filters (env vars, kept off the --arg list to match the OUTPUT_FORMAT
# convention used elsewhere in this directory):
#   PACKAGE=main              restrict to one package
#   KIND_PREFIX=interface     restrict to kinds starting with <string>
#   INCLUDE_GENERATED=true    do not exclude generated:true rows (excluded by default)
#
# Heuristic:
#   - Strip a trailing `(?i)V?[0-9]+` from each declaration's .name to obtain a
#     `base_name`. Names with no suffix retain their full name as base and parse
#     as version 0 (the pre-versioning baseline).
#   - Group by (package, base_name). Require ≥ 2 distinct full names per group,
#     and require at least one member to carry an explicit version suffix so a
#     coincidental group of two unversioned bare names is dropped.
#   - Within a group, sort members by version ascending, then file, then line.
#
# shapes_match: true when every member shares the same non-null shape_sig.
# Strong signal that the migration left a near-clone behind. When false the
# pair has diverged; still worth surfacing but lower confidence.
#
# Known false-positive class: protocol-suffix names like `IPv4` / `IPv6` strip
# to base `IP` with versions 4 and 6. Documented; no acceptlist at v1.
# Out of scope: `NewFoo` / `LegacyFoo` / `OldFoo` prefix variants — separate
# query under the same #226 bullet.
#
# cluster_id format:  versioned-type-pairs:<package>/<base_name>
#
#! query: versioned-type-pairs
#! shape: cluster
#! catalog: type-catalog
#! env: PACKAGE string ""
#! env: KIND_PREFIX string ""
#! env: INCLUDE_GENERATED string ""
#! formats: text, jsonl
#! desc: Cluster type-catalog decls sharing a base name after stripping V<n>/<n> suffix — stalled-migration signal.

include "_canonical";

# Strip a trailing version suffix from a name. Returns the stripped base
# (equal to the full name if no suffix matches).
def strip_version_suffix:
  if test("(?i)V?[0-9]+$") then
    sub("(?i)V?[0-9]+$"; "")
  else
    .
  end;

# Parse a trailing version suffix as integer. Returns 0 when no suffix matches
# (the unversioned baseline sorts first within a cluster).
def parse_version:
  if test("[0-9]+$") then
    (capture("(?<v>[0-9]+)$") | .v | tonumber)
  else
    0
  end;

($ENV.PACKAGE           // "")          as $pkg_filter
| ($ENV.KIND_PREFIX     // "")          as $kind_filter
| (($ENV.INCLUDE_GENERATED // "") == "true") as $include_gen
| [ entries[]
    | select($include_gen or ((.generated // false) != true))
    | select($pkg_filter  == "" or .package == $pkg_filter)
    | select($kind_filter == "" or ((.kind // "") | startswith($kind_filter)))
    | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object" or . == "drizzle-table")
    | . + {
        base_name: (.name | strip_version_suffix),
        version:   (.name | parse_version)
      }
  ]
| group_by([.package, .base_name])
| map(select((map(.name) | unique | length) >= 2))
| map(select(any(.[]; .version > 0)))
| map({
    cluster_id: cluster_id_single_name("versioned-type-pairs"; "\(.[0].package)/\(.[0].base_name)"),
    query: "versioned-type-pairs",
    shape: "cluster",
    base_name: .[0].base_name,
    package: .[0].package,
    shapes_match: ((map(.shape_sig) | unique) as $sigs
                   | ($sigs | length) == 1 and ($sigs[0] // null) != null),
    members: (sort_by(.version, .file, .line)
              | map({
                  name,
                  kind,
                  version,
                  package,
                  file,
                  line,
                  shape_sig,
                  touched_in_window: (.touched_in_window // false)
                }))
  })
| sort_by(.package, .base_name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    (.members | length) as $n
    | (if .shapes_match then "shapes match" else "shapes diverge" end) as $shape_label
    | (.members[-1].name) as $newest_name
    | "\($newest_name) <-> \(.base_name)  (\($shape_label), \($n) members) cid=\(.cluster_id)\n"
      + (.members
          | map("  \(if .touched_in_window then "*" else " " end) \(.name) [\(.kind)] \(.package):\(.file):\(.line)"
                + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end))
          | join("\n"))
  end
