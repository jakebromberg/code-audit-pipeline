/// Production type — `is_test` must be false.
pub struct RealType {
    pub x: u32,
}

/// Production free fn — the function catalog's `is_test` must be false.
pub fn real_helper(x: u32) -> u32 {
    let a = x + 1;
    let b = a + 1;
    b
}

/// Item-level `#[cfg(test)]` on a FREE FN — `is_test` must be true. Regression
/// for the function walker only consulting `mod` attrs (the type catalog tags
/// the sibling item-level `#[cfg(test)]` struct; the func catalog must match).
#[cfg(test)]
pub fn item_level_test_fn() -> u32 {
    let a = 1;
    let b = a + 1;
    b
}

#[cfg(test)]
mod tests {
    /// Declared inside a `#[cfg(test)]` module — `is_test` must be true.
    pub struct TestOnly {
        pub y: u32,
    }

    /// Fn inside a `#[cfg(test)]` module — `is_test` must be true (nested path).
    pub fn nested_test_fn() -> u32 {
        let a = 1;
        let b = a + 1;
        b
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

/// Regression: `#[cfg(any(test, ...))]` is also active in NON-test builds
/// whenever the other branch holds, so it must NOT gate as test-only —
/// `is_test` must be false. (A bare-`test`-appears-positively walk got this
/// wrong.)
#[cfg(any(test, feature = "fastest"))]
pub struct AnyTestOrFeature {
    pub a: u32,
}

/// `#[cfg(all(test, unix))]` genuinely requires `test`, so it gates as
/// test-only — `is_test` must be true.
#[cfg(all(test, unix))]
pub struct AllTestAndUnix {
    pub b: u32,
}

/// A production type whose impl carries a `#[cfg(test)]` METHOD directly (not a
/// `#[cfg(test)]` impl or mod). The function catalog must tag that one method
/// `is_test` true while the sibling production method stays false.
pub struct MixedImpl;

impl MixedImpl {
    pub fn prod_method(&self) -> u32 {
        1
    }

    #[cfg(test)]
    pub fn test_method(&self) -> u32 {
        2
    }
}
