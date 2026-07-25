# copied-literal-candidates.jq — numeric and static-string literals that look
# like copies of one another: the same normalized value repeated across files
# under the same knob name (clusters), and same-value private bindings whose
# names say they mean the same thing (pairs). Strings and numerics never unify
# on value_norm — a kind-class bucket keeps the string "2" apart from the
# number 2 (int and float remain a single class, preserving 6.0 == 6).
#
# Run:  jq -L pipeline/queries -r --argjson min_sites 3 --argjson min_files 2 \
#         -f pipeline/queries/copied-literal-candidates.jq literal-catalog.json
#       (-r for raw text output. Both --argjson flags are REQUIRED for raw jq —
#        jq compiles the whole program before running it and rejects undefined
#        variables at parse time, so an in-jq fallback cannot exist.
#        `code-audit query` injects the front-matter defaults automatically.)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson min_sites 3 \
#                --argjson min_files 2 -f pipeline/queries/copied-literal-candidates.jq literal-catalog.json
#
# Two-section output:
#   [copied-literal clusters]   same (value_norm, label, kind_class) at
#                               ≥ min_sites sites — so a string never clusters
#                               with a numeric of equal text; string cluster_ids
#                               carry a "#str" suffix to stay unique.
#                               spanning ≥ min_files files. Files are counted
#                               package-qualified (package:file) — two package
#                               roots can carry the same relative path, per
#                               the contract's file-duplicates rationale.
#                               label is the knob the literal is attached to:
#                               binding_name for bindings, arg_label (falling
#                               back to callee) for call arguments. Bindings
#                               and arguments sharing a label deliberately
#                               co-cluster — a named constant plus raw call
#                               sites of the same label+value is a partially-
#                               extracted constant.
#   [copied-binding pairs]      bindings only: equal value_norm AND equal
#                               kind_class, different
#                               package-qualified file OR different
#                               enclosing_type, and names
#                               that contain one another case-insensitively
#                               (contained name ≥ 4 chars, so "cap"/"capacity"
#                               stays quiet). Catches the single mirrored
#                               constant that a site-count gate can't see.
#                               Bindings already covered by a fired cluster
#                               are excluded (mirrors function-duplicates'
#                               exact-cluster exclusion).
#
# Provenance: wxyc-ios-64 PR #565 — review found a private
# `placeholderCornerRadius: CGFloat = 6.0` silently mirroring another type's
# private `cornerRadius: CGFloat = 6.0` (a copy that must track another value,
# and copies break), plus hand-copied 12pt insets drifting against a 16pt
# header gutter. Both instances are invisible to declaration catalogs; the
# literal catalog exists to surface them.
#
# Restraint: this is NOT a magic-number linter — SwiftLint's `no_magic_numbers`
# already flags per-site literals, statefully and with in-editor context. The
# in-lane signal here is *cross-file repetition of the same value under the
# same name*, which needs the whole catalog as input. Hence the deny-lists
# (numeric -1/0/1/2, and empty / single-char / boolean-word strings, are
# structure, not shared knobs) and the min_files floor.
#
# Direction: pair left/right follows catalog order (envelope-free, like
# near-duplicates); cluster_id sorts the two location keys.
#
# cluster_id formats:
#   copied-literal-cluster:<label>=<value_norm>   (the group key itself)
#   copied-literal-pair:Loc+Loc                   (sorted package:file:line:label keys)
#
#! query: copied-literal-candidates
#! shape: cluster, pair
#! catalog: literal-catalog
#! arg: min_sites number 3
#! arg: min_files number 2
#! formats: text, jsonl
#! desc: Repeated numeric and string literals — cross-file value clusters and copied-binding pairs.

include "_canonical";

# The knob name a literal is attached to. Argument rows prefer the argument
# label over the callee ("frame(width: 44)" clusters as `width`, not `frame`).
def lit_label:
  if .form == "binding" then .binding_name
  else (.arg_label // .callee)
  end;

# Kind class for clustering: strings must never unify with numerics on
# value_norm alone (the string "2" is not the number 2). int and float stay a
# single "num" class so the documented cross-spelling unification (6.0 == 6 ==
# 0x6) is preserved; string is its own "str" class.
def kind_class:
  if .value_kind == "string" then "str" else "num" end;

# Per-occurrence location key. Literal rows carry no `name` field (occurrence
# catalog, per the contract's exemption), so loc_key from _canonical — which
# reads .name — can't be used; the label plays the name's role.
def lit_key:
  "\(.package):\(.file):\(.line):\(lit_label)";

# Member `name` for the renderer: the source spelling in context, e.g.
# "cornerRadius = 6.0", "frame(width: 44)", "padding(12)".
def lit_name:
  if .form == "binding" then "\(.binding_name) = \(.value)"
  elif .arg_label != null then "\(.callee)(\(.arg_label): \(.value))"
  else "\(.callee)(\(.value))"
  end;

# Envelope member: the renderer's closed field set (name/kind/package/file/line),
# with the form standing in as kind.
def lit_member:
  {name: lit_name, kind: .form, package, file, line};

# Distinct files spanned by a group of occurrences, package-qualified. Bare
# `.file` under-counts: `file` is relative to its walked root, and two package
# roots can carry the same relative path (`Sources/Utils.swift`) — the same
# reason file-duplicates package-qualifies its path keys.
def pkg_file_count:
  [.[] | "\(.package):\(.file)"] | unique | length;

entries as $all
| ([ $all[]
     | select((.generated // false) != true)
     # -1/0/1/2 are structural (indices, toggles, halves), not shared knobs.
     | select(.value_norm | IN("-1", "0", "1", "2") | not)
     # String analogue of the numeric deny-list: empty and single-character
     # strings and the boolean words are structure/sentinels, not shared knobs.
     # Gated on kind so numerics are untouched (a length-1 numeric like "5" is a
     # real value).
     | select(
         if .value_kind == "string"
         then ((.value_norm | length) >= 2)
              and (.value_norm | ascii_downcase | IN("true", "false") | not)
         else true
         end)
   ]) as $lits

# --- Section 1: cross-file (value_norm, label) clusters ---
| ( $lits
    | group_by([.value_norm, lit_label, kind_class])
    | map(select(
        length >= $min_sites
        and pkg_file_count >= $min_files))
  ) as $fired
| ( $fired
    | map(. as $grp
      | { cluster_id: "copied-literal-cluster:\($grp[0] | lit_label)=\($grp[0].value_norm)\(if $grp[0].value_kind == "string" then "#str" else "" end)",
          query: "copied-literal-cluster",
          shape: "cluster",
          value_norm: $grp[0].value_norm,
          label: ($grp[0] | lit_label),
          file_count: ($grp | pkg_file_count),
          members: ($grp | sort_by(.package, .file, .line) | map(lit_member))
        })
    | sort_by(-(.members | length), .cluster_id)
  ) as $clusters

# Occurrences already reported by a fired cluster — exclude from the pair lane.
| ([ $fired[][] | lit_key ] | unique) as $covered

# --- Section 2: copied-binding pairs ---
| ( [ [ $lits[]
        | select(.form == "binding" and .binding_name != null)
        | select(lit_key | IN($covered[]) | not)
      ] as $bindings
      | range(0; $bindings | length) as $i
      | range($i + 1; $bindings | length) as $j
      | $bindings[$i] as $a | $bindings[$j] as $b
      | select($a.value_norm == $b.value_norm
               and ($a | kind_class) == ($b | kind_class))
      # Same file AND same type = locally visible siblings; not a copy smell.
      # File identity is package-qualified: two package roots can carry the
      # same relative path, and those files are NOT mutually visible.
      | select($a.package != $b.package
               or $a.file != $b.file
               or ($a.enclosing_type // "") != ($b.enclosing_type // ""))
      | ($a.binding_name | ascii_downcase) as $an
      | ($b.binding_name | ascii_downcase) as $bn
      | select(
          (($an | length) >= 4 and ($bn | contains($an)))
          or (($bn | length) >= 4 and ($an | contains($bn))))
      | { cluster_id: cluster_id_sorted_pair("copied-literal-pair"; ($a | lit_key); ($b | lit_key)),
          query: "copied-literal-pair",
          shape: "pair",
          value_norm: $a.value_norm,
          left:  ($a | lit_member + {binding_name, value, value_norm, is_static: (.is_static // false), access, enclosing_type}),
          right: ($b | lit_member + {binding_name, value, value_norm, is_static: (.is_static // false), access, enclosing_type})
        }
    ]
    | sort_by(.cluster_id)
  ) as $pairs

# --- Format ---
| if output_format == "jsonl" then
    (($clusters[], $pairs[]) | @json)
  else
    "=== copied-literal clusters, ≥\($min_sites) sites across ≥\($min_files) files (\($clusters | length)) ===\n"
    + ( $clusters
        | map(
            "[\(.label) = \(.value_norm), \(.members | length) sites, \(.file_count) files] cid=\(.cluster_id)\n"
            + (.members
               | map("    \(.name) [\(.kind)] — \(.package):\(.file):\(.line)")
               | join("\n"))
          )
        | join("\n\n")
      )
    + "\n\n=== copied-binding pairs (\($pairs | length)) ===\n"
    + ( $pairs
        | map(
            "[= \(.value_norm)] \(.left.binding_name) <-> \(.right.binding_name) cid=\(.cluster_id)\n"
            + "    left:  \(.left.name) — \(.left.package):\(.left.file):\(.left.line)\(if .left.enclosing_type != null then " (\(.left.enclosing_type))" else "" end)\n"
            + "    right: \(.right.name) — \(.right.package):\(.right.file):\(.right.line)\(if .right.enclosing_type != null then " (\(.right.enclosing_type))" else "" end)"
          )
        | join("\n\n")
      )
  end
