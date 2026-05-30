# cross-package-backward-imports.jq -- find shared/ files importing from main/.
# This is a layering violation: shared is the canonical-types package and
# should never depend on a downstream consumer. No existing tool (madge,
# eslint-plugin-import, depcruise) frames the check this way -- they're all
# file-level and language-locked; this query operates on the project's
# `--root` vs `--shared` cut.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/cross-package-backward-imports.jq files.json
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r \
#         -f pipeline/queries/cross-package-backward-imports.jq files.json
#
# Input: the sibling `files.json` artifact emitted by type-catalog.mjs's
# --emit-files flag (per docs/pipeline-contract.md §files artifact).
# The query consumes ONLY files.json -- no catalog join needed.
#
# Granularity: one cluster row per *shared* file that has any backward
# import(s), with all backward edges grouped into a top-level
# `backward_imports[]` array on the row. Mirrors orphan-infer-model.jq's
# "top-level finding metadata + members[0] = the entity with the finding"
# convention -- the violator is the shared file, the main targets are
# evidence. Per-edge granularity would inflate the cluster count without
# adding insight: a shared file with 5 backward imports is one problem to
# fix, not five.
#
# Filters intentionally NOT applied in v1:
#   - type_only edges still flagged. A shared type depending on a main type
#     is still a layering signal even if erased at runtime. Text mode
#     annotates `(type-only)`; JSONL consumers can post-filter on
#     `.backward_imports[].type_only` if they want runtime-only edges.
#   - is_test files still flagged. A shared/test file backward-importing
#     from main is still inverted. members[0].is_test is exposed so
#     consumers can post-filter.
#   - dynamic-import edges still flagged. Visible via
#     `.backward_imports[].kind`.
#
# Known v1 limitation: the resolver in --emit-files handles relative paths
# only (no tsconfig.json `paths` aliases, no CommonJS `require()`). An
# alias-based backward import won't surface until the resolver learns
# aliases; documented in docs/pipeline-contract.md §files artifact.
#
# cluster_id format: cross-package-backward-imports:shared:<path>
# Per-shared-file -- never collides within a single run.
#
# Envelope: shape: "cluster", members of length 1 (the violating shared
# file). The backward-edge list goes on `backward_imports[]` at the top
# level so the renderer stays shape-aware.

#! shape: cluster

include "_canonical";

[ entries[]
  | select(.package == "shared")
  | . as $f
  | [.imports[] | select(.package == "main")] as $back
  | select(($back | length) > 0)
  | {
      cluster_id: cluster_id_single_name(
        "cross-package-backward-imports";
        "\($f.package):\($f.path)"
      ),
      query: "cross-package-backward-imports",
      shape: "cluster",
      backward_imports: $back,
      members: [{
        path: $f.path,
        package: $f.package,
        is_test: $f.is_test
      }]
    }
]
| sort_by(.members[0].package, .members[0].path)
| .[]
| if output_format == "jsonl" then
    @json
  else
    .members[0] as $m
    | "  \($m.path)  <-  " + (
        .backward_imports
        | map("main:" + .path + (if .type_only then " (type-only)" else "" end))
        | join(", ")
      )
      + "  cid=\(.cluster_id)"
  end
