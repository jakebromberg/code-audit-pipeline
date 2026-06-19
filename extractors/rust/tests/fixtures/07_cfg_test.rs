/// Production type — `is_test` must be false.
pub struct RealType {
    pub x: u32,
}

#[cfg(test)]
mod tests {
    /// Declared inside a `#[cfg(test)]` module — `is_test` must be true.
    pub struct TestOnly {
        pub y: u32,
    }
}

/// Regression: `#[cfg(not(test))]` gates code IN for production builds, so
/// `is_test` must be false. A substring match on the cfg predicate would see
/// "test" and wrongly invert this to true.
#[cfg(not(test))]
mod production_only {
    pub struct ProdOnly {
        pub z: u32,
    }
}

/// Regression: a feature whose name merely contains the substring "test"
/// (here `fastest`) is not a test gate — `is_test` must be false.
#[cfg(feature = "fastest")]
mod fast {
    pub struct FastPath {
        pub w: u32,
    }
}

/// Regression: `#[cfg(test)]` applied directly to an item (not a `mod`) must
/// still set `is_test` — item-level detection, not only module-level.
#[cfg(test)]
pub struct ItemLevelTestOnly {
    pub v: u32,
}
