# migration-progress.jq — measure % migrated from one shape to another and list
# stragglers (decls still on the old shape AND touched during the audit window).
#
# Active refactors live between PRs; no individual diff answers "are we done
# yet?". This query counts declarations matching each shape, computes a percent
# migrated, and surfaces the touched-in-window decls still on the old shape so
# the cutover driver can chase them down.
#
# Run:  jq -L pipeline/queries -r \
#         --arg old_sig "id:number" \
#         --arg new_sig "id:string" \
#         --arg label   "Id type migration" \
#         -f pipeline/queries/migration-progress.jq catalog.json
#
# Optional filters (env vars, kept off the --arg list to match the OUTPUT_FORMAT
# convention used elsewhere in this directory):
#   PACKAGE=main              restrict to one package
#   KIND_PREFIX=interface     restrict to kinds starting with <string>
#   INCLUDE_GENERATED=true    do not exclude generated:true rows (excluded by default)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --arg old_sig ... \
#         -f pipeline/queries/migration-progress.jq catalog.json
#
# Required args: old_sig, new_sig, label.
#
# Discovery: to list candidate shape_sigs by frequency, use shape-sig-frequency.jq.
#
# Output: progress line + stragglers, ordered by package:file:line. JSONL output
# carries `on_old`, `on_new`, `percent_migrated`, `stragglers`, and the
# `no_matches` and `sigs_identical` edge-case flags.
#
# cluster_id format:  migration-progress:<label>  (one cluster per invocation)

include "_canonical";

# Optional filters live in $ENV (jq errors on undefined --arg, so $ENV is the
# clean default-empty-string mechanism here, matching OUTPUT_FORMAT's pattern).
($ENV.PACKAGE         // "")           as $pkg_filter
| ($ENV.KIND_PREFIX   // "")           as $kind_filter
| (($ENV.INCLUDE_GENERATED // "") == "true") as $include_gen
| ([.[]
    | select($include_gen or ((.generated // false) != true))
    | select($pkg_filter  == "" or .package == $pkg_filter)
    | select($kind_filter == "" or ((.kind // "") | startswith($kind_filter)))]) as $all
| ([$all[] | select(.shape_sig == $old_sig)]) as $on_old
| ($on_old | length) as $n_old
| ($n_old + ([$all[] | select(.shape_sig == $new_sig)] | length)) as $total
| (if $total == 0 then 0 else (($total - $n_old) * 100 / $total | floor) end) as $pct
| ([$on_old[] | select(.touched_in_window // false)]
   | sort_by(.package, .file, .line)) as $stragglers
| {
    cluster_id: cluster_id_single_name("migration-progress"; $label),
    query: "migration-progress",
    label: $label,
    old_sig: $old_sig,
    new_sig: $new_sig,
    on_old: $n_old,
    on_new: ($total - $n_old),
    percent_migrated: $pct,
    no_matches: ($total == 0),
    sigs_identical: ($old_sig == $new_sig and $old_sig != ""),
    stragglers: ($stragglers | map({name, kind, package, file, line}))
  }
| if output_format == "jsonl" then
    @json
  else
    if .sigs_identical then
      "Migration: \(.label)\n  ! old_sig and new_sig are identical (\(.old_sig)) — % migrated is meaningless. cid=\(.cluster_id)"
    elif .no_matches then
      "Migration: \(.label)\n  (no matches: 0 on old, 0 on new) cid=\(.cluster_id)"
    else
      "Migration: \(.label)\n"
      + "  Progress: \(.on_new) on new / \(.on_old) on old (\(.percent_migrated)% migrated) cid=\(.cluster_id)\n"
      + "  Stragglers (touched in window, still on old shape):\n"
      + (if (.stragglers | length) == 0 then
          "    (none — clean)"
        else
          (.stragglers
            | map("    \(.name) [\(.kind)] — \(.package):\(.file):\(.line)")
            | join("\n"))
        end)
    end
  end
