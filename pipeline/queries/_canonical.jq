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
# Tolerant of bad env input — `CROSS_REPO_STALE_DAYS=""` (unset in CI),
# `"7d"` (operator confusing the unit suffix), or `"0"` (operator trying
# to disable staleness with the wrong knob) all fall back to the default
# rather than crashing the query or marking every repo divergent. The
# substrate's publish-side reads this env too, so an invalid value would
# corrupt both sides — better to ignore it consistently here.
def stale_threshold_days:
  (($ENV.CROSS_REPO_STALE_DAYS // "") | tonumber? // null) as $parsed
  | if $parsed == null or $parsed <= 0 then 7 else $parsed end;

# ─── Already-abstracted cluster helpers (issue #217) ──────────────────────
#
# Cluster queries downrank groups whose members already share a non-trivial
# protocol — five conformers of `MusicService` aren't a missing-abstraction
# candidate, they're an EXISTING abstraction. The substrate signal:
#
#   - Every cluster member carries `conforms_to[]` listing the protocol
#     identifiers from its inheritance clause.
#   - The catalog's protocol records (`kind: "interface"`) declare member
#     requirements (in `fields[]`).
#
# A protocol is "non-trivial" when it has ≥2 declared requirements
# (`fields | length >= 2`). Marker protocols like Sendable / Equatable /
# Hashable declare zero requirements (the standard library synthesizes
# their behaviour) and correctly drop out of the downrank signal.
#
# This `fields | length` heuristic stands in for the principled signal
# (`references_count`, the count of typed references inside the protocol's
# surface) which the Swift extractor doesn't yet emit. Known limitations
# documented per the heuristic:
#
#   * OVERPREDICTS on test-local protocols with rich method signatures
#     but no cross-module references — the cluster will downrank.
#     Precision loss, not a missing finding. Acceptable for v1.
#   * UNDERPREDICTS on composition-only protocols (`protocol Codable:
#     Decodable & Encodable {}`) — zero declared members. This is the
#     intended behaviour: the downrank wants protocols with method
#     bodies that justify shared-implementation, not naming sugar.
#
# The next iteration (separate issue) will wire `references_count` for
# Swift protocols and swap the predicate; that's a strict precision win.

# Intersection of N string arrays. Inputs are sorted-unique by the
# `conforms_to[]` extractor contract; this returns the common elements
# in the order they appear in the first array. Empty input → []; single
# input passes through; the reduce step starts from arr[0] and filters
# by membership in each subsequent array via `IN()` (the same pattern
# from PR review 5763acba on `default-impl-candidates.jq`).
def intersect_string_arrays:
  if length == 0 then []
  elif length == 1 then .[0]
  else .[0] as $first
       | reduce .[1:][] as $next ($first; map(select(IN($next[]))))
  end;

# Build a name → {kind, fields} lookup over interface records in the
# catalog. The `group_by(.name) | add | unique` merge handles Swift's
# `protocol Foo { ... } / extension Foo { ... }` case where the same
# protocol name appears in two records — the union of their fields[]
# is the protocol's full requirement surface. (This convention was
# codified by PR review 5763acba on `default-impl-candidates.jq`.)
#
# Consumed via:  (. | protocols_index) as $protocols_idx
# Each cluster query computes this once at the top of its pipeline.
def protocols_index:
  [ entries[] | select(.kind == "interface") ]
  | group_by(.name)
  | map({key: .[0].name,
         value: {kind: "interface",
                 fields: (map(.fields // []) | add | unique)}})
  | from_entries;

# Build a name → merged conforms_to[] lookup across ALL records sharing a
# name. Swift declares conformance both inline (`struct Foo: P`) and
# retroactively via extensions (`extension Foo: P {}`) — each is a separate
# catalog record, so reading `conforms_to` off a type's own record misses
# extension-declared conformances. Queries that demote already-abstracted
# pairs should look decls up here instead of trusting the record's own field.
#
# Name-level merge (not loc-keyed) is intentional and mirrors
# protocols_index: retroactive conformance can be declared in any package or
# file, so there is no reliable structural join back to one declaration.
# Same-name types in different packages over-merge; documented limitation
# shared with protocols_index (PR review 5763acba convention).
#
# Interface records are EXCLUDED: a protocol's conforms_to is inheritance
# (`protocol X: P`), not concrete conformance, and merging it would credit a
# same-name concrete type with the protocol's parents — a false demotion.
# Interface members keep their inheritance signal because consumers apply
# with_conformance (below), which unions the record's own conforms_to back in.
#
# Consumed via:  (. | conformance_index) as $conf_idx
# then per decl: $decl | with_conformance($conf_idx)
def conformance_index:
  [ entries[] | select(.kind != "interface") | select(.conforms_to != null) | {name, conforms_to} ]
  | group_by(.name)
  | map({key: .[0].name, value: (map(.conforms_to) | add | unique)})
  | from_entries;

# Augment a decl with its full conformance surface: the conformance_index
# lookup (inline + extension-declared, minus interface records) unioned with
# the decl's own conforms_to (restoring an interface's inheritance signal).
# The companion to conformance_index — apply per decl before demotion checks
# so the union step can't be forgotten.
def with_conformance($idx):
  . + {conforms_to: ((($idx[.name] // []) + (.conforms_to // [])) | unique)};

# Predicate over a cluster's member list. Returns true when the cluster
# is "already abstracted" — all members share at least one `conforms_to`
# entry, AND that shared entry resolves to a non-trivial protocol in
# $protocols_idx (kind == "interface" with fields | length >= 2).
#
# Input: an array of decl objects (each carrying a sorted-unique
# `conforms_to[]`). Pair queries pass a 2-element array; cluster queries
# pass the N-element cluster.
#
# Returns false if any member has no `conforms_to` (intersection collapses
# to []), or if the shared entries don't resolve to non-trivial protocols.
def is_already_abstracted_cluster($protocols_idx):
  ([.[] | (.conforms_to // [])] | intersect_string_arrays) as $shared
  | $shared
  | any(. as $name
        | ($protocols_idx[$name] // null)
        | . != null and .kind == "interface" and ((.fields // []) | length) >= 2);
