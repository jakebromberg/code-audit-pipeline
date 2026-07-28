# module-symbol-density.jq — flag oversized / high-symbol-density modules: the
# "god module" before-shape. A file that declares far more callables and types
# than its peers is carrying too many responsibilities; it is the deterministic
# before-state of a decomposition refactor (carve the god module into a package
# of focused modules).
#
# Motivating case: a sibling repo's `lookup/orchestrator.py` (~970 lines, many
# responsibilities) was decomposed across a PR series into strategies/,
# matching, concurrency, validation, artwork, and rowless modules, then guarded
# by a hand-rolled per-file line-budget table. This query is the catalog-native,
# cross-codebase version of that guardrail: instead of a project-specific ceiling
# table, it flags files whose declaration count is both large in absolute terms
# AND a high multiple of the codebase's own median file — so it ports across
# repos without a hand-tuned absolute threshold.
#
# Cross-KIND query: the "too many responsibilities" tell spans BOTH callables
# (function / method rows) and types (interface / struct / model rows). Per the
# public-api-leaks precedent, the primary positional input is the
# FUNCTION-catalog and the type-catalog is mounted as `$types` via the second
# `#! catalog:` kind (the binary wires `type-catalog` → `--slurpfile types`;
# raw jq must pass `--slurpfile types type-catalog.json` itself). The two entry
# sets are merged and grouped by the package-qualified file.
#
# Run:  jq -L pipeline/queries -r \
#         --slurpfile types type-catalog.json \
#         --argjson min_decls 12 --argjson ratio 2 \
#         -f pipeline/queries/module-symbol-density.jq function-catalog.json
#        (-r for raw multi-line text output. `--slurpfile types <path>` and BOTH
#         --argjson flags are REQUIRED for raw jq: jq compiles the whole program
#         before running it and rejects undefined variables ($types, $min_decls,
#         $ratio) at parse time, so an in-jq `try … catch <default>` fallback
#         cannot exist. `code-audit query` injects the front-matter defaults and
#         wires the slurpfile automatically; raw jq has no equivalent.)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r \
#                --slurpfile types type-catalog.json \
#                --argjson min_decls 12 --argjson ratio 2 \
#                -f pipeline/queries/module-symbol-density.jq function-catalog.json
#
# Thresholds (tunable):
#   --argjson min_decls 12   absolute floor: a file must declare at least N
#                            symbols to be a candidate (default 12 via #! arg).
#                            Suppresses the small-codebase degenerate case where
#                            the median is 1-2 and every slightly-larger file
#                            would otherwise clear the ratio.
#   --argjson ratio 2        ratio-to-median multiplier: a file is flagged only
#                            when its declaration count is at least N× the median
#                            declaration count across all (surviving) files
#                            (default 2 via #! arg). This is the PORTABLE signal —
#                            it needs no per-codebase absolute ceiling, and it
#                            correctly stays quiet on a uniformly-large codebase
#                            (every file big ⇒ ratio ≈ 1 ⇒ nothing flagged).
#
# Flag condition:  decl_count >= min_decls  AND  decl_count >= ratio * median.
# Both gates must hold. Densest-first ordering surfaces the strongest god
# modules at the top.
#
# Signals emitted per flagged file:
#   - decl_count        primary signal: functions + methods + types sharing the
#                       package-qualified file (the "too many responsibilities"
#                       tell).
#   - body_lines_total  secondary signal: summed `body_line_count` over the
#                       file's callables (an LOC-of-callables proxy for the "too
#                       much code" tell). Type rows carry no body and contribute
#                       0; a null body (short-body function below the extractor's
#                       --min-body-lines gate) also contributes 0.
#   - ratio_to_median   decl_count / median, one-decimal — how many times the
#                       typical file this module is.
#   - kind_breakdown    per-kind declaration tally (function / method / interface
#                       / type-alias-object / …) so an agent can see WHAT the
#                       module is dense in before proposing the cut.
#
# Restraint (implemented as filters):
#   - `generated` files are excluded outright AND never counted toward the
#     median. A large generated file is regenerated, not decomposed — it is not
#     a refactor target, and letting it into the median would inflate the
#     denominator and mask real god modules.
#   - `is_test` files are excluded by default (a big test file is not the same
#     smell) and, when excluded, are also kept out of the median. Opt them in
#     with `INCLUDE_TESTS=true`, mirroring copied-from-header's INCLUDE_GENERATED
#     convention; opted-in test files then count toward BOTH the median and the
#     candidate set.
#
# Median rationale: the median (not the mean) is the robust central-tendency
# measure — a single 900-line god module barely moves the median but would drag
# the mean up toward itself, weakening its own ratio. Median keeps the outlier's
# ratio honest.
#
# KNOWN LIMITATIONS (documented; not blocking):
#   - Requires BOTH catalogs. A file whose declarations live only in a catalog
#     kind that was not extracted (e.g. function-catalog present, type-catalog
#     absent) is under-counted. Run both extractors for a complete count.
#   - `body_lines_total` is a callables-only proxy: it omits module-level
#     statements, type bodies, comments, and imports. It is a secondary tie-break
#     signal, not an authoritative line count. The primary flag is decl_count.
#   - The query surfaces the file and its density; it does NOT propose the cut
#     points (unlike mark-section-density, which can read `// MARK:` seams). The
#     decomposition seam is left to the agent layer consuming the cluster.
#
# cluster_id format:  module-symbol-density:<package>__<file>
# One cluster per flagged file. The package is included (with the `__` directed-
# separator precedent shared by mark-section-density / persistence-store-field-
# density / versioned-type-pairs) so the same relative path in two packages
# (`main/util.py` and `shared/util.py`) produces two distinct clusters and is
# counted as two files, never merged.
#
#! query: module-symbol-density
#! shape: cluster
#! catalog: function-catalog, type-catalog
#! arg: min_decls number 12
#! arg: ratio number 2
#! env: INCLUDE_TESTS string ""
#! formats: text, jsonl
#! desc: Oversized / high-symbol-density modules (functions + methods + types) — god-module before-shape.

include "_canonical";

# Median of a numeric array. Returns null for an empty array (guarded by the
# caller). Even-length arrays average the two central elements; odd-length pick
# the center. Mirrors coverage.jq's median convention so the two agree.
def median(arr):
  (arr | sort) as $s
  | ($s | length) as $n
  | if $n == 0 then null
    elif ($n % 2) == 1 then $s[($n / 2 | floor)]
    else (($s[$n / 2 - 1] + $s[$n / 2]) / 2)
    end;

# $min_decls / $ratio must be supplied externally (--argjson for raw jq, auto-
# injected by `code-audit query` from the #! arg defaults). $types is the
# slurped type-catalog (--slurpfile types for raw jq, auto-wired by the binary
# from the second #! catalog kind). jq rejects undefined variables at parse
# time, so in-jq fallbacks are not possible — see the docstring.
(($ENV.INCLUDE_TESTS // "") == "true") as $include_tests
# Merge the function-catalog (positional input) with the slurped type-catalog.
# Both share the canonical location/flag fields; only function rows carry
# body_line_count, which the type rows simply lack (→ 0 via `// 0`).
| ( [ entries[] ] + [ $types[0] | entries[] ] )
| map(select((.generated // false) != true))
| map(select($include_tests or ((.is_test // false) != true)))
# One group per package-qualified file — package first so same-path-different-
# package files stay distinct.
| group_by([.package, .file])
| map({
    package: .[0].package,
    file: .[0].file,
    decl_count: length,
    # Summed callable body lines. Type rows have no body_line_count; short-body
    # functions carry null. Both collapse to 0.
    body_lines_total: (map(.body_line_count // 0) | add),
    touched_in_window: any(.touched_in_window == true),
    first_line: (map(.line) | min),
    kind_breakdown: (group_by(.kind) | map({key: .[0].kind, value: length}) | from_entries)
  })
| . as $files
# Median declaration count across every surviving file — the portable
# denominator. Null only when there are no surviving files at all.
| (median([ $files[] | .decl_count ])) as $median
| [ $files[]
    | select($median != null and $median > 0)
    | select(.decl_count >= $min_decls)
    | select(.decl_count >= ($ratio * $median))
    | (((.decl_count / $median) * 10 | floor) / 10) as $ratio_to_median
    | {
        cluster_id: cluster_id_single_name("module-symbol-density"; "\(.package)__\(.file)"),
        query: "module-symbol-density",
        shape: "cluster",
        package: .package,
        file: .file,
        decl_count: .decl_count,
        body_lines_total: .body_lines_total,
        median_decls: $median,
        ratio_to_median: $ratio_to_median,
        kind_breakdown: .kind_breakdown,
        touched_in_window: .touched_in_window,
        # Single-member cluster: the file IS the cluster (mirrors mark-section-
        # density). members[] wraps it so the shape-aware markdown renderer
        # prints a meaningful row; the file value doubles as the member name
        # because this query operates at file granularity.
        members: [{
          name: .file,
          kind: "file",
          package: .package,
          file: .file,
          line: .first_line,
          touched_in_window: .touched_in_window
        }]
      }
  ]
# Densest-first: highest declaration count at the top, body-lines as tiebreak,
# then package/file for a stable order across gojq / stedolan jq.
| sort_by(-.decl_count, -.body_lines_total, .package, .file)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.decl_count) decls / \(.body_lines_total) body-lines / \(.ratio_to_median)x median] cid=\(.cluster_id)\n"
    + "  \(if .touched_in_window then "*" else " " end) \(.package):\(.file):\(.members[0].line)\n"
    + "    kinds: "
    + (.kind_breakdown | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(", "))
  end
