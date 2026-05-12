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
