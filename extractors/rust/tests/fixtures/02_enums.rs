/// Enum with unit, tuple, and struct variants.
pub enum Classification {
    Landed,
    Active(String),
    LandedByContent { matched: usize, total: usize },
    Diverged(usize, usize),
}

/// Enum with explicit discriminants.
pub enum Priority {
    Low = 1,
    High = 10,
}
