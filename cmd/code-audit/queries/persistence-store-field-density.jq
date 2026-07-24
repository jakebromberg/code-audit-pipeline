# persistence-store-field-density.jq — flag named types that inject a
# persistence-store field (a `UserDefaults` / `DefaultsStorage` handle) AND
# carry several stored properties alongside it. These are the boilerplate
# "settings bag" types whose per-property get/set plumbing is the consolidation
# target: the type owns a store handle and hand-rolls N keyed accessors over it.
# A high stored-property count next to an injected store is the deterministic
# before-state of a keyed-defaults refactor (a @propertyWrapper, a macro, or a
# single generic store abstraction).
#
# This is Detector A (Tier 1) of the userdefaults-keytable-boilerplate strategy
# candidate: it uses only catalog fields that the type-catalog already emits
# today (`fields_structured[].type` / `.name` / `.is_static`, plus `generated`,
# `is_test`, `conforms_to`, and the location trio). No schema change required.
#
# Run:  jq -L pipeline/queries --argjson threshold 3 \
#         -rf pipeline/queries/persistence-store-field-density.jq catalog.json
#        (-r for raw multi-line text output. --argjson threshold is REQUIRED for
#         raw jq: jq compiles the whole program before running it and rejects
#         undefined variables at parse time, so an in-jq `try $threshold catch 3`
#         fallback cannot exist. `code-audit query` injects the front-matter
#         default below automatically; raw jq has no equivalent and must pass
#         --argjson.)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries --argjson threshold 3 \
#                -rf pipeline/queries/persistence-store-field-density.jq catalog.json
#
# Threshold (tunable):
#   --argjson threshold 3   flag types with at least N stored properties beside
#                           the store field (default 3 via #! arg). Lowering it
#                           surfaces smaller settings bags; the count is what
#                           suppresses already-DRY low-count service types that
#                           merely hold a store handle.
#
# Persistence-store set (tunable in-query): the `persistence_store_types` def
# below lists the type names that count as an injected store. Extend it there
# for project-specific store wrappers (e.g. a `KeyValueStore` façade).
#
# Logic:
#   - Positive kind filter: only stored-field-bearing record kinds participate
#     (type-alias-object / zod-object / drizzle-table). `type-alias-union` is
#     excluded — enum cases populate fields_structured but are not stored
#     properties — and `interface` is excluded — protocols hold no stored state.
#   - A member is a "store field" when its `type`, after trailing optional
#     (`?` / `!`) sugar is stripped, is in `persistence_store_types`.
#   - `stored_property_count` counts non-static members (`is_static == false`),
#     EXCLUDING the store field(s) themselves. Static members (shared
#     singletons, cached keys) are not per-instance persisted state.
#   - Flag a type when it has ≥1 store field AND stored_property_count ≥ threshold.
#
# Restraint (implemented as filters): `generated` and `is_test` types are
# excluded outright. `conforms_to` is surfaced as context on each row rather
# than used to suppress — an agent reads it to judge whether an existing
# protocol is already the consolidation seam.
#
# KNOWN RECALL GAP (by design for Tier 1): types that persist via *inline*
# `UserDefaults.standard.set(_, forKey: "literal")` calls in accessor bodies —
# with no injected store *field* on the type — are INVISIBLE to this detector.
# The accessor body is not represented in the type catalog, so there is nothing
# to cluster on. Closing that gap needs a `persists_via_accessor` extractor
# signal, which is Detector B (Tier 2, future) — out of scope here.
#
# cluster_id format:  persistence-store-field-density:<package>__<TypeName>
# One cluster per candidate type. The package is included (with the `__`
# directed-separator precedent shared by mark-section-density and
# versioned-type-pairs) so two same-named types in different packages produce
# distinct ids; a bare `<TypeName>` would collide. The `<prefix>:` still holds,
# and the type name remains in the id.
#
#! query: persistence-store-field-density
#! shape: cluster
#! catalog: type-catalog
#! arg: threshold number 3
#! formats: text, jsonl
#! desc: Types injecting a UserDefaults/DefaultsStorage field alongside many stored props — keyed-defaults boilerplate.

include "_canonical";

# Persistence-store type names. Extend this list for project-specific store
# wrappers. A member whose (optional-stripped) type is in this set is treated
# as an injected persistence-store handle rather than persisted state.
def persistence_store_types: ["DefaultsStorage", "UserDefaults", "NSUserDefaults"];

# Strip a trailing optional / implicitly-unwrapped-optional marker and any
# surrounding whitespace from a verbatim type string, so `DefaultsStorage?` and
# `UserDefaults!` both compare equal to their bare spelling. Optional-sugar
# stripping only — deeper normalization (e.g. `Optional<UserDefaults>`) is out
# of scope; the injected-store convention writes the sugared form.
def bare_type: (. // "") | sub("^\\s+"; "") | sub("\\s+$"; "") | sub("[?!]+$"; "");

# $threshold must be supplied externally (--argjson for raw jq, auto-injected by
# `code-audit query` from the #! arg default above). jq rejects undefined
# variables at parse time, so an in-jq fallback is not possible — see the
# docstring.
[ entries[]
  | select((.generated // false) != true)
  | select((.is_test // false) != true)
  # Positive kind filter — stored-field-bearing record kinds only (see header).
  | select(.kind == "type-alias-object" or .kind == "zod-object" or .kind == "drizzle-table")
  | (.fields_structured // []) as $members
  # Store fields: members whose optional-stripped type is a persistence store.
  | [ $members[] | select((.type | bare_type) as $t | (persistence_store_types | any(. == $t))) ] as $store_fields
  | select(($store_fields | length) > 0)
  | ($store_fields | map(.name)) as $store_field_names
  # Candidate stored members: non-static members that are not store fields.
  | [ $members[]
      | select((.is_static // false) != true)
      | select((.name as $n | $store_field_names | any(. == $n)) | not)
    ] as $stored_members
  | ($stored_members | length) as $stored_property_count
  | select($stored_property_count >= $threshold)
  | {
      cluster_id: cluster_id_single_name("persistence-store-field-density"; "\(.package)__\(.name)"),
      query: "persistence-store-field-density",
      shape: "cluster",
      name: .name,
      package,
      file,
      line,
      touched_in_window: (.touched_in_window // false),
      conforms_to: (.conforms_to // []),
      store_fields: ($store_fields | map({name, type})),
      stored_property_count: $stored_property_count,
      stored_members: ($stored_members | map({name, type})),
      # Single-member cluster: the candidate type IS the cluster. members[] wraps
      # it so the shape-aware markdown renderer prints a meaningful row.
      members: [{
        name: .name,
        kind: .kind,
        package,
        file,
        line,
        touched_in_window: (.touched_in_window // false),
        conforms_to: (.conforms_to // []),
        store_fields: ($store_fields | map({name, type})),
        stored_property_count: $stored_property_count,
        stored_members: ($stored_members | map({name, type}))
      }]
    }
]
# Densest-first: most stored properties surface at the top. Tiebreak by
# package/file/name for a stable order across gojq / stedolan jq.
| sort_by(-.stored_property_count, .package, .file, .name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.stored_property_count) stored props] \(.name) cid=\(.cluster_id)\n"
    + "  \(if .touched_in_window then "*" else " " end) \(.package):\(.file):\(.line)\n"
    + "    store field(s): \(.store_fields | map("\(.name):\(.type)") | join(", "))\n"
    + "    stored members: \(.stored_members | map("\(.name):\(.type)") | join(", "))\n"
    + "    conforms:       \(if (.conforms_to | length) == 0 then "(none)" else (.conforms_to | join(", ")) end)"
  end
