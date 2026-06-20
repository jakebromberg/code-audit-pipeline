/// Under a `generated/` path segment — `generated` flag must be true.
pub struct Generated {
    pub field: u32,
}

/// Free fn under a `generated/` path — the function row's `generated` flag must
/// be true (the func catalog must thread `ctx.generated`, like the type catalog).
pub fn generated_fn(field: u32) -> u32 {
    let a = field + 1;
    let b = a + 1;
    b
}
