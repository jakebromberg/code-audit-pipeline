# mark-section-density.jq — flag long files carrying many `// MARK:` section
# markers as maintainer-pre-labeled refactor candidates. The maintainer has
# already partitioned the file into named seams; high MARK count plus long
# line count makes the cut points explicit.
#
# Reads the `mark_count` / `line_count` / `mark_labels` fields emitted by the
# file-hashes extractor when invoked with `--scan-marks` (extractor v0.6.0+).
# Without `--scan-marks` those fields are absent and the query emits nothing.
#
# Run:  jq -L pipeline/queries --argjson min_marks 6 --argjson min_lines 400 \
#         -rf pipeline/queries/mark-section-density.jq file-hashes.json
#       (file-hashes must have been generated with --scan-marks; otherwise
#        the fields are absent and the query emits zero rows. Both --argjson
#        flags are REQUIRED for raw jq invocation — jq compiles the whole
#        program before running it and rejects undefined variables at parse
#        time, so an in-jq `try $min_marks catch 6` fallback cannot exist.
#        `code-audit query` injects the front-matter defaults below
#        automatically; raw jq has no equivalent and must pass --argjson.)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries --argjson min_marks 6 \
#                --argjson min_lines 400 -rf pipeline/queries/mark-section-density.jq file-hashes.json
#
# Thresholds (tunable):
#   --argjson min_marks 6       require at least N MARK sections (default 6 via #! arg)
#   --argjson min_lines 400     require strictly more than N total lines (default 400 via #! arg)
#
# Calibration notes (from #221 body): wxyc-ios-64's AudioPlayerController.swift
# is 800+ lines / 13 MARKs. The 6 / 400 defaults were chosen so that single
# files of moderate density do not flood the report. Recalibrate per project.
#
# Known v1 limitations (documented; not blocking):
#
#   - Swift is the calibration target. Other languages (TypeScript, Python)
#     don't typically use `// MARK:` markers; on those files mark_count = 0
#     and the file silently fails the threshold. Adding a `// #region` /
#     `# region` parser would be a follow-up.
#
#   - The MARK_RE in the extractor anchors at line start with optional indent
#     and accepts both `// MARK: <title>` and `// MARK: - <title>` (the `-`
#     separator is purely visual). Inline `// MARK:` inside a function body
#     comment still counts — Swift convention is top-level only, but the
#     regex is line-anchored, not scope-aware. False-positive risk negligible
#     in practice.
#
#   - The query does not propose the refactor; it surfaces the labels as
#     "suggested cut points." Refactor judgment is left to the agent layer
#     consuming the cluster.
#
# cluster_id format:  mark-section-density:<package>__<file>
# One cluster per matched file; the `__` separator (per the versioned-type-pairs
# precedent) keeps the prefix/package/file boundary unambiguous even when Swift
# packages emitted by resolveSwiftPackage carry colons (e.g. `app:iOS`).
#
#! query: mark-section-density
#! shape: cluster
#! catalog: file-hashes
#! arg: min_marks number 6
#! arg: min_lines number 400
#! formats: text, jsonl
#! desc: Long files with many `// MARK:` sections — maintainer-pre-labeled refactor candidates.

include "_canonical";

# $min_marks and $min_lines must be supplied externally (--argjson for raw jq,
# auto-injected by `code-audit query` from the #! arg defaults above). jq
# rejects undefined variables at parse time, so an in-jq fallback is not
# possible — see the docstring above.
[ entries[]
  | select((.mark_count // null) != null)
  | select((.line_count // null) != null)
  | select(.mark_count >= $min_marks)
  | select(.line_count > $min_lines)
  # mark_labels may be null/absent (defense for malformed catalogs) OR may be
  # the wrong type entirely; in either case fall back to []. The `if type`
  # check guards against type drift (e.g. mark_labels: {}), which the simpler
  # `// []` alternative would NOT catch — `//` only substitutes on null/false.
  | ((.mark_labels | if type == "array" then . else [] end)) as $labels
  | ($labels | if length > 0 then .[0].line else 1 end) as $first_line
  | {
      cluster_id: cluster_id_single_name("mark-section-density"; "\(.package)__\(.file)"),
      query: "mark-section-density",
      shape: "cluster",
      package,
      file,
      mark_count,
      line_count,
      mark_labels: $labels,
      # Members carry name/kind/line so the binary's markdown renderer
      # (internal/render/cluster.go::renderMember) prints a meaningful row
      # instead of a bare ' — pkg:file' bullet. The `file` value doubles as
      # the symbol name because this query operates at file granularity.
      members: [{
        name: .file,
        kind: "file",
        package,
        file,
        line: $first_line,
        mark_count,
        line_count,
        mark_labels: $labels
      }]
    }
]
# Densest-first ordering so the report renderer surfaces the strongest signals
# at the top. Tiebreaks by line_count desc, then by package/file ascending so
# the order is stable across gojq / stedolan jq.
| sort_by(-.mark_count, -.line_count, .package, .file)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.mark_count) marks / \(.line_count) lines] cid=\(.cluster_id)\n"
    + "    \(.package):\(.file)\n"
    + (.mark_labels
        | map("      L\(.line)  \(if .label == "" then "(unlabeled)" else .label end)")
        | join("\n"))
  end
