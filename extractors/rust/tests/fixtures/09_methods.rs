//! Methods and trait methods, exercising the `exported` rules:
//!   - inherent impl method    -> exported = method visibility
//!   - trait-impl method       -> exported = true (documented over-report)
//!   - trait default method    -> exported = enclosing trait visibility
//!   - signature-only trait fn -> null body fields

struct PrivateType;
pub struct PublicType;

trait PrivateTrait {
    fn secret(&self) -> usize;
}

pub trait PublicTrait {
    /// Default method (has a body) -> body fields populated; exported via the
    /// trait's `pub` visibility.
    fn described(&self) -> usize {
        let base = 10;
        let bump = base + 1;
        bump
    }
    /// Signature-only (no body) -> null body fields; still exported (pub trait).
    fn required(&self, factor: usize) -> usize;
}

impl PublicType {
    /// Inherent `pub` method -> exported = true.
    pub fn visible(&self, amount: usize) -> usize {
        let scaled = amount * 2;
        let adjusted = scaled + 1;
        adjusted
    }
    /// Inherent private method -> exported = false.
    fn hidden(&self) -> usize {
        let secret = 42;
        let doubled = secret * 2;
        doubled
    }
}

/// Trait impl over a PRIVATE trait + PRIVATE type. syn gives these methods
/// `Inherited` visibility, but they're reachable wherever the trait + type are
/// in scope, so the extractor marks them exported = true (the documented
/// over-report that keeps `public-api-leaks.jq` from under-reporting).
impl PrivateTrait for PrivateType {
    fn secret(&self) -> usize {
        let a = 1;
        let b = a + 2;
        b
    }
}
