//! Other half of the duplicate-body pair (see `10_dup_body_a.rs`). Same body,
//! different function name and file -> identical `body_hash`.

pub fn compute_beta(seed: usize) -> usize {
    let stage_one = seed + 100;
    let stage_two = stage_one * 2;
    let stage_three = stage_two - 3;
    stage_three
}
