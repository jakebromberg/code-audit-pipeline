# copied-from-header.jq — surface files whose top comment self-confesses as a
# fork. Reads the `header_match` field emitted by the file-hashes extractor when
# invoked with `--scan-header` (extractor v0.6.0+). Each file with a non-null
# `header_match` becomes one single-member cluster row — the finding *is* the
# per-file phrase match.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/copied-from-header.jq file-hashes.json
#       (file-hashes must have been generated with --scan-header; otherwise
#        the field is absent and the query emits zero rows.)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/copied-from-header.jq file-hashes.json
#
# Phrase list (lives in the extractor — see extractors/file-hashes/file-hashes.mjs HEADER_PHRASES):
#   "copied from", "fork of", "based on", "duplicate of", "ported from"
# Case-insensitive substring match against the first ~30 lines of each file.
#
# Filters out generated files (`.d.ts`, `generated/`, `*.generated.swift`) —
# upstream codegen confessions are not actionable in the same way maintainer-
# authored forks are. Override with `INCLUDE_GENERATED=true` (mirrors
# `versioned-type-pairs.jq` / `migration-progress.jq` convention).
#
# Known v1 limitations (documented; not blocking):
#
#   - License-attribution phrases ("based on the MIT-licensed implementation by
#     X") surface as positives. Triage path: read the cluster, dismiss
#     license-attribution rows by eye — same workflow versioned-type-pairs
#     documents for IPv4/IPv6. A future `EXCLUDE_PHRASES` env knob can fold a
#     deny-list in if real-world false-positive rate justifies it.
#
#   - "See also <other file>" phrases (lower precision per #220 body) are NOT
#     in the v1 list — phrase ergonomics differ enough that scoping calls for a
#     follow-up.
#
#   - The query does not resolve the *target* of the copy (`// Copied from
#     DebugPanel` does not point at the matching DebugPanel.swift). Resolving
#     that requires a cross-file name lookup; out of scope here.
#
# cluster_id format:  copied-from-header:<package>:<file>
# One cluster per matched file; uniqueness guaranteed by the (package, file)
# pair the file-hashes extractor enforces.
#
#! query: copied-from-header
#! shape: cluster
#! catalog: file-hashes
#! env: INCLUDE_GENERATED string ""
#! formats: text, jsonl
#! desc: Files whose top comment self-confesses as a fork ("copied from", "fork of", etc.).

include "_canonical";

(($ENV.INCLUDE_GENERATED // "") == "true") as $include_gen
| [ entries[]
    | select($include_gen or ((.generated // false) != true))
    | select(.header_match != null)
    | {
        cluster_id: cluster_id_single_name("copied-from-header"; "\(.package):\(.file)"),
        query: "copied-from-header",
        shape: "cluster",
        package,
        file,
        phrase: .header_match.phrase,
        line: .header_match.line,
        text: .header_match.text,
        members: [{
          package,
          file,
          line: .header_match.line,
          phrase: .header_match.phrase,
          text: .header_match.text
        }]
      }
  ]
| sort_by(.package, .file)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.phrase)] cid=\(.cluster_id)\n"
    + "    \(.package):\(.file):\(.line)\n"
    + "      \(.text)"
  end
