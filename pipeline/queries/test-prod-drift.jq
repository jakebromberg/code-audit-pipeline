# test-prod-drift.jq — surface near-duplicate type pairs where exactly one side
# is in a test path (XOR on .is_test). Captures the case where a manually-
# maintained fixture has drifted from the prod model it mirrors.
#
# Run:  jq -L pipeline/queries -r --argjson threshold 0.5 -f pipeline/queries/test-prod-drift.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson threshold 0.5 -f pipeline/queries/test-prod-drift.jq catalog.json
#
# Threshold default suggestion is 0.5 (lower than near-duplicates' 0.7) because
# test fixtures legitimately drop optional fields, dragging Jaccard down. Tune
# upward for tighter recall.
#
# `--argjson threshold N` is REQUIRED — jq errors at compile time on an undefined variable.
#
# Asymmetry: exactly one side must be `is_test: true` (XOR). Same-test-side pairs
# (two fixtures of each other) are a different finding — they belong in a
# fixture-sprawl query, not here.
#
# Back-compat: catalogs predating the `is_test` schema delta have no field on
# their rows. `.is_test // false` defaults missing to false. Old catalogs flow
# through with both sides false → XOR false → no pair emitted. Graceful degradation.
#
# Output ordering: the prod (non-test) side is rendered first in each pair —
# the reader's mental model is "did the fixture drift from prod?" so anchoring
# on the prod side is what the eye wants to see. The cluster_id stays
# sorted-pair (symmetric) since pair identity is direction-free.
#
# False-positive class: a test fixture that legitimately mirrors prod for
# isolation reasons. Estimated 30–50% of emitted pairs in real codebases;
# the absolute count is small (single digits per audit) so manual triage is fine.
#
# cluster_id format:  test-prod-drift:LocA+LocB  (sorted location keys —
#                                                 package:file:line:name)

include "_canonical";

[ .[] | select(.fields and (.fields | length) >= 3 and (.generated // false) != true) ] as $bs
| [
    range(0; $bs | length) as $i
    | range($i + 1; $bs | length) as $j
    | $bs[$i] as $x | $bs[$j] as $y
    # XOR on is_test — cheaper to filter on a boolean than to compute Jaccard
    # for pairs we'd discard anyway.
    | select(($x.is_test // false) != ($y.is_test // false))
    # Reorder so $a is the prod (non-test) side and $b is the test side.
    | (if ($x.is_test // false) then $y else $x end) as $a
    | (if ($x.is_test // false) then $x else $y end) as $b
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $bf
    | ($af + $bf | unique | length) as $u
    | select($u > 0)
    | ([$af[] | select(. as $f | $bf | index($f) != null)] | length) as $ic
    | ($ic / $u) as $jacc
    | select($jacc >= $threshold and $jacc < 1.0 and ($af | length) >= 3 and ($bf | length) >= 3)
    | { cluster_id: cluster_id_sorted_pair("test-prod-drift"; loc_key($a); loc_key($b)),
        query: "test-prod-drift",
        jacc: $jacc, a: $a, b: $b, af: $af, bf: $bf, intersection: $ic, union: $u }
  ]
| sort_by(-(.jacc))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] prod \(.a.package):\(.a.name)  <->  test \(.b.package):\(.b.name) cid=\(.cluster_id)\n"
    + "    prod: \(.a.kind) — \(.a.file):\(.a.line)\n"
    + "    test: \(.b.kind) — \(.b.file):\(.b.line)\n"
    + "    prod fields: \(.af | join(", "))\n"
    + "    test fields: \(.bf | join(", "))"
  end
