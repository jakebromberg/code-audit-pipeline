# _canonical.jq — cluster_id derivation helpers and output-mode utilities.
#
# Every cluster query in `pipeline/queries/` includes this library so that each
# output row carries a stable, substrate-emitted `cluster_id` field. Downstream
# scorers and agent harnesses reference clusters by this id verbatim rather
# than re-deriving an id from cluster contents (which V4 measured as a load-
# bearing source of cross-trial divergence).
#
# Address: GitHub issue #5 ("V5 substrate: substrate-emitted cluster_ids").
#
# ─── Cluster envelope (ADR-0003) ──────────────────────────────────────────
#
# Every JSONL row carries a `shape` field naming one of three envelopes. The
# binary's markdown renderer (PR 4) dispatches purely on `shape`; queries
# never need a per-query renderer. Queries also declare `#! shape: <value>`
# in their front-matter (single value, or comma-separated for dual-section
# queries) — see ADR-0002 for the front-matter convention.
#
#   shape: "cluster"   N members grouped by a common key. Envelope fields:
#                      cluster_id, query, shape, members[]. The members[]
#                      array contains one decl object per group member.
#                      Includes single-member rows (e.g., orphan-infer-model,
#                      generic-convention-bound) — the envelope wraps the
#                      decl as members: [{...}] of length 1 so the renderer
#                      stays shape-aware, not arity-aware.
#
#   shape: "pair"      Two endpoints. Envelope fields: cluster_id, query,
#                      shape, left, right. The two endpoints are full decl
#                      objects. Field-set variants use the same prefix:
#                      left_fields/right_fields, left_only/right_only,
#                      left_slots/right_slots, etc. Pair direction is
#                      ENVELOPE-FREE: directed (subset-pairs: left ⊂ right)
#                      and asymmetric (test-prod-drift: left=prod right=test;
#                      cross-package-shape-near-duplicates: left=main
#                      right=shared) queries document their convention in
#                      the file header. The renderer treats all pairs
#                      uniformly; query-specific role labels are restored in
#                      text mode.
#
#   shape: "metric"    Single-value or summary row. Envelope fields:
#                      cluster_id, query, shape, plus arbitrary query-
#                      specific payload (percent_migrated, count, etc.).
#                      No structural envelope fields beyond the trio.
#
# Field renames that landed in PR 1 (do not regress; keep in sync with
# docs/pipeline-contract.md "Cluster envelope" section):
#
#   decls       → members           (cluster shape)
#   locations   → members           (cross-package-shadows-any only)
#   a / b       → left / right      (pair shape)
#   af / bf     → left_fields / right_fields
#   a_only / b_only       → left_only / right_only
#   a_slots / b_slots     → left_slots / right_slots
#   swap_tokens_a / swap_tokens_b → left_swap_tokens / right_swap_tokens
#   sub / sup             → left / right   (subset-pairs; direction in header)
#   sub_fields / sup_fields → left_fields / right_fields
#   main / shared         → left / right   (cross-package-shape-near-duplicates)
#   main_only / shared_only → left_only / right_only
#   a_only_count          → diff_line_count (generic-function-candidates: renamed
#                                            for clarity — it's the count of
#                                            differing body lines, not the
#                                            a-endpoint's exclusive-line count)
#
# Cluster_id format conventions (authoritative; see docs/pipeline-contract.md):
#
#   exact-duplicates:A+B+...                      sorted names, '+' separator
#   name-collisions:Name                          just the name
#   cross-package-shadows:Name                    asymmetric main↔shared
#   cross-package-shadows-any:Name                symmetric N-package
#   cross-package-shape-near-duplicates:Loc+Loc   sorted by package:file:line:name
#   cross-package-shape-near-duplicates-any:Loc+Loc   sorted, '+' separator
#   near-duplicates:Loc+Loc                       sorted location keys
#   near-duplicates-any:Loc+Loc                   sorted location keys
#   subset-pairs:LocSub__LocSup                   directed; sub then sup, '__' separator
#   function-duplicates-exact:Loc+Loc+...         sorted by package:file:line:name
#   function-duplicates-near:Loc+Loc              sorted
#   file-duplicates-exact:pathA+pathB+...         sorted, repo-relative paths
#   file-duplicates-norm:pathA+pathB+...          sorted, repo-relative paths
#   versioned-type-pairs:Pkg__BaseName             directed: package then base
#                                                 name; uses '__' (the
#                                                 directed-pair separator)
#                                                 because the package field
#                                                 can legitimately contain
#                                                 '/' (e.g., 'Shared/Generated')
#
# Pair-based queries (near-duplicates, subset-pairs, etc.) use *location keys*
# (`package:file:line:name`) on each endpoint rather than bare names because
# Swift and TypeScript both let the same name appear on multiple records
# (`enum Foo` plus `extension Foo` plus another file's `Foo`). Name-only pair
# ids collide whenever multiple records share a name — observed on wxyc-ios-64
# `PlayerState`/`PlaybackState` (each has an enum decl + an extension decl).
# Function-duplicates already used the same convention for the same reason.
#
# Grouped queries (exact-duplicates, *-collisions, *-shadows*) use bare names
# in the id because the row IS the group keyed by name (or shape_sig) — the
# members[] field lists all decls. Collision-by-name within the same row is
# not a collision-of-rows.
#
# Known limitation: exact-duplicates uses sorted member names as its cluster_id
# discriminator. Two distinct shape_sig clusters whose member name sets happen
# to be identical would emit the same cluster_id. Practically rare in real
# codebases (identical names usually correlate with identical shapes — that's
# what duplication is). If observed, qualify the cluster_id with shape_sig.
#
# Output format: every query supports two modes:
#   default (or OUTPUT_FORMAT=text)   human-readable text (the V5/V6 behavior),
#                                     with `cid=<cluster_id>` annotated on each
#                                     cluster header
#   OUTPUT_FORMAT=jsonl               JSONL — one cluster object per line,
#                                     consumed by the V7 trial harness
#
# Invoke with: jq -L pipeline/queries -rf pipeline/queries/<query>.jq <input>
# The `-L` flag tells jq where to find this library; without it `include`
# fails. Documented in each query's header.

def output_format: ($ENV.OUTPUT_FORMAT // "text");

# Schema v1.1 (per docs/pipeline-contract.md) wraps the catalog as
#   {schema_version: "1.1", extractor: {...}, entries: [...]}
# Queries that used to start with `[ .[] | ... ]` now use `[ entries[] | ... ]`.
# This helper also accepts the legacy bare-array form for one release so older
# catalog dumps (and synthetic test fixtures predating the wrapper) keep working.
# Drop the back-compat branch when the deprecation window closes.
def entries:
  if type == "array" then .
  elif type == "object" and has("entries") then .entries
  else error("expected catalog: top-level must be an array (v1.0) or an object with .entries (v1.1)")
  end;

# Sorted-names cluster_id: prefix + ":" + sorted_names_joined_with_plus.
def cluster_id_sorted_names(prefix; names):
  prefix + ":" + (names | sort | join("+"));

# Single-name cluster_id: prefix + ":" + name. For per-name clusters
# (name-collisions, cross-package-shadows-*).
def cluster_id_single_name(prefix; name):
  prefix + ":" + name;

# Sorted-pair cluster_id: prefix + ":" + sort([a, b]) joined with '+'. For
# pairwise-near-duplicate queries where the pair has no canonical direction.
def cluster_id_sorted_pair(prefix; a; b):
  prefix + ":" + ([a, b] | sort | join("+"));

# Directed-pair cluster_id: prefix + ":" + sub + "__" + sup. For subset-pairs
# specifically — the pair is *directed* (A ⊂ B; swapping changes the id).
def cluster_id_directed_pair(prefix; sub; sup):
  prefix + ":" + sub + "__" + sup;

# Sorted-paths cluster_id: prefix + ":" + sorted_paths_joined_with_plus. For
# file-duplicates — caller passes already-repo-relative paths.
def cluster_id_sorted_paths(prefix; paths):
  prefix + ":" + (paths | sort | join("+"));

# Record-location key: stable per-decl id used to disambiguate same-name
# records (functions or types) inside a cluster. Concatenation of package,
# file, line, name. Used by all pair-based queries' cluster_ids.
def loc_key(decl):
  "\(decl.package):\(decl.file):\(decl.line):\(decl.name)";

# Backwards-compatible alias — keep the older name working since downstream
# helpers and tests reference it. New code should prefer loc_key.
def fn_location_key(decl): loc_key(decl);

# Stable sort for single-member cluster rows: orders by the same four fields
# that loc_key composes (package, file, line, name) on members[0]. Used by
# dead-code, generic-convention-bound, public-api-leaks — every query whose
# rows wrap a single decl into members[{...}] and need a deterministic order.
def sort_by_member_loc:
  sort_by(.members[0].package, .members[0].file, .members[0].line, .members[0].name);

# ─── Naming utilities ─────────────────────────────────────────────────────
#
# Qualified-name → enclosing-type extraction. Used by default-impl-candidates
# to bucket function records by the type they belong to.
#
# Drops the last `.`-separated segment of a qualified name. For Swift records
# the catalog emits names in the form `Type.method` or `OuterType.NestedType.method`;
# stripping the last segment yields the enclosing type. Free functions (no dot)
# return unchanged, which keeps them distinct from each other in clustering.
#
# Examples:
#   type_of("Foo.bar")         → "Foo"
#   type_of("Foo.Bar.baz")     → "Foo.Bar"   (nested type's enclosing type)
#   type_of("freeFunction")    → "freeFunction"
#   type_of("")                → ""          (defensive; not expected in practice)
def type_of(name):
  (name | split(".")) as $parts
  | if ($parts | length) <= 1 then name
    else ($parts[0:-1] | join("."))
    end;

# Identifier-token extraction. Used by generic-function-candidates to find
# substitution patterns between near-duplicate function body lines.
#
# Splits on non-identifier characters (anything outside `[A-Za-z0-9_]`) and
# keeps non-empty tokens. ASCII-only by design — Swift permits Unicode
# identifiers (e.g., `let π = 3.14`), but they would be silently elided
# here. The pattern matches the standard `[A-Za-z0-9_]` identifier convention
# of the substrate plants this is used against.
def tokens_of:
  split("[^A-Za-z0-9_]+"; "") | map(select(length > 0));

# ─── Cross-repo filter helpers (issue #155) ───────────────────────────────
#
# Predicates used by cross-repo queries to separate published-package symbols
# from repo-local ones. Loaded as part of `_canonical.jq` rather than a
# parallel `lib/` file because this file already plays the helper-library
# role (loc_key, output_format, tokens_of, cluster_id_*) and docs/plans/README
# pins the convention.
#
# Caveat: `origin_package` is currently emitted only on `kind: "import"`
# rows (per PR #196 / issue #152). Type-alias / interface / function rows
# do not carry it; calling `is_published` on a type row returns false. If
# a future query wants to filter type rows by their publisher of origin,
# the right move is a join across import edges, not a row-level predicate.

# is_published — true if this row originated from a published package
# (its `origin_package` field is a non-empty string). Designed for filtering
# cross-repo name-collisions down to the published-only subset where the
# collision is meaningful (two repos importing the same external API rather
# than two repos coincidentally naming an internal symbol the same thing).
def is_published:
  (.origin_package // null) as $p
  | ($p | type) == "string" and ($p | length) > 0;

# is_repo_local — logical complement of is_published. A row whose origin
# is the repo itself (no `origin_package`, or empty/null). Useful when the
# question is "how many of this name's collisions are internal-only?"
def is_repo_local:
  is_published | not;

# stale_threshold_days — the staleness cutoff in days. Reads
# CROSS_REPO_STALE_DAYS env (default 7). The same env is read by
# refresh-index.mjs at publish-time when computing each repo's
# `latest.status` field; coverage.jq and preflight-versions.jq use this
# helper at query-time. If the env changed between publish and query,
# coverage surfaces both index.json's precomputed `status` AND a
# freshly-recomputed age so any divergence is visible.
#
# Empty-string handling: jq's `//` only catches null/false, not "". A
# `CROSS_REPO_STALE_DAYS=""` (common in CI when a variable is declared
# but not yet assigned) would otherwise reach `tonumber` on the empty
# string and crash with `Expected JSON value`. We coerce empty to the
# default explicitly via `select(length > 0)`.
def stale_threshold_days:
  (($ENV.CROSS_REPO_STALE_DAYS // "") | select(length > 0) // "7")
  | tonumber;
