# generic-convention-bound.jq — declarations whose field types reference a
# type-parameter-style identifier (T, K, TStats, TInput, …) that the
# declaration's own `generics` list does not bind.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/generic-convention-bound.jq catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/generic-convention-bound.jq catalog.json
#
# Catches cases like:
#   type SyncResult = { ok: boolean; stats: TStats }
# where `TStats` appears in fields but the declaration is not declared generic —
# usually a sign the type was meant to be `SyncResult<TStats>`.
#
# HEURISTIC: this query uses regex on raw field-type text. It has known limits:
#   - false positives: app-domain types that happen to start with a capital T
#     followed by another capital (Java/Hungarian conventions in some projects
#     use `TFoo` for non-generic types);
#   - false negatives: lowercase or non-conventional type parameter names.
# It will graduate to a precise structured cut once an extractor emits a
# resolved `type_refs` list per field — see issue #146 (TS extractor: emit
# `extends` + `references` edges, schema v1.1) for the live design. (The
# earlier #131 ticket that proposed a dedicated `type_refs` field was closed
# as not-planned; the work folded into #146.) When the edges land, this query
# rewrites from a regex on raw text into an anti-join on the structured
# array. The heuristic stays available as a fallback for catalogs that
# pre-date the schema bump.
#
# Optional knobs:
#   EXTRA_BUILTINS=Foo,Bar    extend the built-in allowlist (comma-joined)
#                             with project-specific ambient types
#                             (e.g. `InferSelectModel`, `z.infer`).
#
# cluster_id format:  generic-convention-bound:<loc_key>
#   where loc_key is `package:file:line:name`. One row per offending decl,
#   so the loc-key form guarantees within-query uniqueness even when two
#   different decls share a name.
#
# Envelope: shape: "cluster", members of length 1. Per-decl findings still
# wrap into the cluster envelope so the renderer stays shape-aware; the
# `suspects` field at the top level carries the unbound type-parameter
# identifiers flagged on this decl.
#
#! query: generic-convention-bound
#! shape: cluster
#! catalog: type-catalog
#! env: EXTRA_BUILTINS string ""
#! formats: text, jsonl
#! desc: Decls whose field types reference unbound T-style identifiers.

include "_canonical";

# Hardcoded TypeScript built-in / standard-library names. Names that are
# legitimately uppercase and not user-authored type parameters.
def builtins: [
  "Pick","Omit","Record","Partial","Required","Readonly",
  "NonNullable","Exclude","Extract","Parameters","ReturnType","Awaited",
  "Promise","Array","Map","Set","WeakMap","WeakSet","Date","RegExp","Error",
  "Object","Function","String","Number","Boolean","Symbol","BigInt","JSON",
  "Math","Iterable","AsyncIterable","Iterator","Generator","Tuple"
];

# Heuristic: looks like a TS-conventional type parameter name.
#   Single-letter from {T, K, V, U, R, E} — the standard {T, K, V} plus
#     {U, R, E} which TS docs commonly use for the second/third parameter.
#   Microsoft-style prefix: TFoo, TInput, TStats — leading T then uppercase.
def looks_like_typeparam: test("^T[A-Z]") or test("^[TKVUER]$");

# Comma-split that tolerates incidental whitespace around items. The contract
# example shows `"generics": "T,U"` (no spaces) and current extractors emit
# that form, but the contract doesn't pin the whitespace; a hand-edited
# fixture or a future extractor could emit `"T, U"`. The same tolerance
# applies to EXTRA_BUILTINS, where users naturally write `"TFoo, TBar"` from
# the shell. Trim each token after split so the allowlist subtraction works
# either way.
def split_trim_csv:
  split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));

(builtins + ($ENV.EXTRA_BUILTINS // "" | split_trim_csv)) as $allowlist
| [entries[]
    | select((.generated // false) != true)
    | select(.fields != null and (.fields | length) > 0)
    | . as $row
    | ($row.generics // "" | split_trim_csv) as $bound
    # Right-of-first-colon: defensive against field types that themselves contain ":".
    | ([$row.fields[] | split(":")[1:] | join(":") | scan("[A-Z]\\w*")] | unique) as $referenced
    | ($referenced - $bound - $allowlist) as $residue
    | ($residue | map(select(looks_like_typeparam))) as $suspects
    | select($suspects | length > 0)
    | {
        cluster_id: cluster_id_single_name("generic-convention-bound"; loc_key($row)),
        query: "generic-convention-bound",
        shape: "cluster",
        suspects: ($suspects | sort),
        members: [{
          name: $row.name,
          kind: $row.kind,
          package: $row.package,
          file: $row.file,
          line: $row.line,
          touched_in_window: ($row.touched_in_window // false),
          generics: ($row.generics // "")
        }]
      }]
| sort_by_member_loc
| .[]
| if output_format == "jsonl" then
    @json
  else
    (.members[0]) as $m
    | "\($m.name) [\($m.kind)] <\(if $m.generics == "" then "—" else $m.generics end)> — \($m.package):\($m.file):\($m.line) cid=\(.cluster_id)\n"
    + "  \(if $m.touched_in_window then "*" else " " end) unbound: \(.suspects | join(", "))"
  end
