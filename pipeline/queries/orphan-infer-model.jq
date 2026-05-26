# orphan-infer-model.jq — surface drizzle tables nothing in the catalog derives
# a TS type from. An "orphan" is either a dead table (no consumer; safe to drop
# or archived schema cruft) or, far more often, a table whose consumer is a
# hand-rolled mirror type that should be replaced with `$inferSelect` /
# `InferSelectModel<typeof T>`. The case study's `FSEntryRaw` finding is the
# archetype.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/orphan-infer-model.jq catalog.json
#
# Optional env knobs (mirroring migration-progress.jq's conventions):
#   INCLUDE_GENERATED=true    do not exclude generated:true drizzle-tables
#                             (default: excluded — Drizzle Kit output rarely
#                             carries user-authored consumers and orphan status
#                             there is uninteresting noise).
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r \
#         -f pipeline/queries/orphan-infer-model.jq catalog.json
#
# Output: per-orphan line with variable name, missing-derivations label
# (`no InferSelect` / `no InferInsert` / `no either`), db_table_name, package,
# file, line. Touched-window asterisk is the same convention as the other
# queries. Sorted by (.missing, .package, .name) for stable diffs.
#
# Join key: drizzle.name (TS identifier) == infer_ref.table. This is the
# variable name, not the SQL string. `InferSelectModel<typeof flowsheet>`
# references the identifier `flowsheet`, not the SQL `flowsheet_entries`.
# The infer_ref.kind values recognized as derivations are the four legal
# values: `InferSelectModel`, `InferInsertModel`, `$inferSelect`, `$inferInsert`.
#
# Known limitations (documented; defer fixes to follow-ups per #127's
# open-questions §1–5):
#   - Tables re-exported through a barrel under a different alias are
#     undetectable because the catalog only records the original identifier.
#   - The inverse query (type-alias-infer-model rows whose .infer_ref.table
#     doesn't resolve to a known drizzle-table.name) is not emitted here.
#
# cluster_id format:  orphan-infer-model:<package>:<file>:<line>:<name>
# Per-decl loc_key — drizzle table names can collide across packages
# (re-export shimming patterns); loc_key keeps each orphan unambiguous within
# the run.

include "_canonical";

(($ENV.INCLUDE_GENERATED // "") == "true") as $include_gen
| . as $all
| ([$all[] | select(.kind == "type-alias-infer-model" and .infer_ref)]) as $derivs
| ($derivs
    | map(select(.infer_ref.kind == "InferSelectModel" or .infer_ref.kind == "$inferSelect"))
    | map(.infer_ref.table) | unique) as $sel_tables
| ($derivs
    | map(select(.infer_ref.kind == "InferInsertModel" or .infer_ref.kind == "$inferInsert"))
    | map(.infer_ref.table) | unique) as $ins_tables
| [ $all[]
    | select(.kind == "drizzle-table")
    | select($include_gen or ((.generated // false) != true))
    | . as $t
    | ($sel_tables | index($t.name)) as $has_sel
    | ($ins_tables | index($t.name)) as $has_ins
    | select($has_sel == null or $has_ins == null)
    | {
        cluster_id: cluster_id_single_name("orphan-infer-model"; loc_key(.)),
        query: "orphan-infer-model",
        name: .name,
        db_table_name: .db_table_name,
        package: .package,
        file: .file,
        line: .line,
        touched_in_window: (.touched_in_window // false),
        generated: (.generated // false),
        missing: (if $has_sel == null and $has_ins == null then "no either"
                  elif $has_sel == null then "no InferSelect"
                  else "no InferInsert" end)
      }
  ]
| sort_by(.missing, .package, .name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "  \(if .touched_in_window then "*" else " " end) \(.name) [\(.missing)] db=\(.db_table_name // "?") — \(.package):\(.file):\(.line) cid=\(.cluster_id)"
  end
