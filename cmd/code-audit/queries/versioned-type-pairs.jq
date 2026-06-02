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
#     `base_name`. Names with no suffix retain their full name as base; names
#     whose strip leaves an empty base (`V2`, `2`, `v3`) are dropped — the
#     group has no semantic anchor.
#   - Each member carries a `has_suffix` flag (true when the name's trailing
#     `(?i)V?[0-9]+` matched anything, even `V0`). This is the explicit-suffix
#     signal; the numeric `.version` field is for ordering only.
#   - Group by (package, base_name). Require ≥ 2 distinct full names per group
#     AND at least one member with `has_suffix == true` (so a coincidental
#     pair of two unversioned bare names that happen to strip to the same base
#     is dropped). `Foo` + `FooV0` is intentionally retained on this rule.
#   - Within a group, sort members by version ascending, then file, then line,
#     then name — the `name` tiebreaker keeps order deterministic across
#     gojq and stedolan/jq when two members share (version, file, line)
#     (e.g., a Swift enum decl + same-file extension decl).
#
# shapes_observed: true when every member carries a non-null, non-empty
# `shape_sig`. The TypeScript extractor emits `shape_sig: ""` for fieldless
# interfaces (`fields.sort().join('|').toLowerCase()` on an empty list), and
# several kinds can legitimately have null shape_sigs; both are "unmeasured"
# rather than "differ".
#
# shapes_match: true iff `shapes_observed` is true and every member shares the
# same `shape_sig`. A strong signal that the migration left a near-clone
# behind. When false WITH shapes_observed true, the pair has diverged. When
# `shapes_observed` is false, `shapes_match` is also false and the text-mode
# label reports "shapes unmeasured" — distinguishing "no observable shape" from
# "shapes disagree."
#
# Known false-positive classes (the regex catches more than `*V<n>` style):
#   - Protocol-suffix names: `IPv4` / `IPv6` strip to base `IP` with versions
#     4 and 6 — fires as a "shapes match" cluster.
#   - Year-suffix names: `Page2018` / `Page2019` strip to base `Page` with
#     versions 2018 / 2019.
#   - Hash-size suffixes: `SHA256` / `SHA512` strip to `SHA`.
#   - Protocol versions: `OAuth2` strips to `OAuth`.
#   - Dimensional names: `Vector2` / `Vector3` strip to `Vector`.
# No acceptlist at v1; the cluster header surfaces the data so the reader
# can dismiss these classes on inspection.
#
# Out of scope: `NewFoo` / `LegacyFoo` / `OldFoo` prefix variants — separate
# query under the same #226 bullet.
#
# cluster_id format:  versioned-type-pairs:<package>__<base_name>
# Uses the documented directed-pair separator (`__`, per `_canonical.jq`).
# The package field can legitimately contain `/` (e.g., `Shared/Generated`),
# so `__` is chosen because neither identifier names nor extractor-assigned
# package labels emit it.
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

# True iff a trailing `(?i)V?[0-9]+` suffix is present (including V0). Carries
# the "this name was explicitly versioned" signal separately from the numeric
# version, so a `FooV0` member can serve as the explicit-suffix anchor in a
# `Foo`+`FooV0` group.
def has_version_suffix:
  test("(?i)V?[0-9]+$");

# Parse a trailing version suffix as integer. Returns 0 when no suffix matches
# (the unversioned baseline sorts first within a cluster). `FooV0` and `Foo`
# both parse as 0 — disambiguated by `has_suffix` upstream.
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
    | select((.kind // "") | startswith("type-alias") or . == "interface" or . == "zod-object" or . == "drizzle-table")
    | . + {
        base_name:  (.name | strip_version_suffix),
        version:    (.name | parse_version),
        has_suffix: (.name | has_version_suffix)
      }
    | select(.base_name != "")
  ]
| group_by([.package, .base_name])
| map(select((map(.name) | unique | length) >= 2))
| map(select(any(.[]; .has_suffix)))
| map(
    ((map(.shape_sig) | unique) as $sigs
     | (all(.[]; (.shape_sig // "") != "")) as $observed
     | {
         cluster_id: cluster_id_directed_pair("versioned-type-pairs"; .[0].package; .[0].base_name),
         query: "versioned-type-pairs",
         shape: "cluster",
         base_name: .[0].base_name,
         package: .[0].package,
         shapes_observed: $observed,
         shapes_match: ($observed and ($sigs | length) == 1),
         members: (sort_by(.version, .file, .line, .name)
                   | map({
                       name,
                       kind,
                       version,
                       has_suffix,
                       package,
                       file,
                       line,
                       shape_sig,
                       touched_in_window: (.touched_in_window // false)
                     }))
       })
  )
| sort_by(.package, .base_name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    (.members | length) as $n
    | (if .shapes_observed then
         (if .shapes_match then "shapes match" else "shapes diverge" end)
       else
         "shapes unmeasured"
       end) as $shape_label
    | ((.members | max_by(.version)).name) as $newest_name
    | "\($newest_name) <-> \(.base_name)  (\($shape_label), \($n) members) cid=\(.cluster_id)\n"
      + (.members
          | map("  \(if .touched_in_window then "*" else " " end) \(.name) [\(.kind)] \(.package):\(.file):\(.line)"
                + (if (.shape_sig // "") != "" then "  sig=" + (.shape_sig | .[0:80]) else "" end))
          | join("\n"))
  end
