//! Half of a cross-file duplicate-body pair. `compute_alpha`'s body is
//! byte-identical to `compute_beta`'s in `11_dup_body_b.rs`, so the two must
//! share a `body_hash` (the copy-paste signal `function-duplicates.jq` clusters).

pub fn compute_alpha(seed: usize) -> usize {
    let stage_one = seed + 100;
    let stage_two = stage_one * 2;
    let stage_three = stage_two - 3;
    stage_three
}
