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
#   cross-package-shape-near-duplicates:A+B       sorted, '+' separator
#   cross-package-shape-near-duplicates-any:A+B   sorted, '+' separator
#   near-duplicates:A+B                           sorted, '+' separator
#   near-duplicates-any:A+B                       sorted, '+' separator
#   subset-pairs:Sub__Sup                         directed (sub then sup), '__' separator
#   function-duplicates-exact:Loc+Loc+...         sorted by package:file:line:name
#   function-duplicates-near:Loc+Loc              sorted
#   file-duplicates-exact:pathA+pathB+...         sorted, repo-relative paths
#   file-duplicates-norm:pathA+pathB+...          sorted, repo-relative paths
#
# Function-duplicates uses location-keyed members (`package:file:line:name`)
# rather than bare names because function names collide more often than type
# names — name-only ids would be ambiguous within a single cluster.
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

# Function-location key: stable per-decl id used to disambiguate same-name
# functions inside a cluster. Concatenation of package, file, line, name.
def fn_location_key(decl):
  "\(decl.package):\(decl.file):\(decl.line):\(decl.name)";
