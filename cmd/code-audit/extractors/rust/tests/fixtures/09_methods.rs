//! Methods and trait methods, exercising the `exported` rules:
//!   - inherent impl method    -> exported = method visibility
//!   - trait-impl method       -> exported = method visibility (Inherited => false)
//!   - trait default method    -> exported = enclosing trait visibility
//!   - signature-only trait fn -> null body fields
//! plus a `Self::Assoc` projection that must NOT surface as a phantom type ref.

struct PrivateType;
pub struct PublicType;

pub trait Projector {
    type Output;
    /// Returns `Self::Output` — a projection onto this trait's own associated
    /// type, not an external type called `Output`. `return_ref` must be null and
    /// `references` must not contain `Output`.
    fn project(&self, seed: usize) -> Self::Output;
    /// The qualified form `<Self as Projector>::Output` — also a Self-projection,
    /// so it too must NOT surface `Output` as a phantom reference.
    fn project_qualified(&self) -> <Self as Projector>::Output;
}

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
/// `Inherited` visibility (Rust forbids `pub` on trait-impl methods), so the
/// extractor reports `exported = false` — honest about the declaration rather
/// than over-reporting `exported = true` for a method nobody outside the module
/// can name.
impl PrivateTrait for PrivateType {
    fn secret(&self) -> usize {
        let a = 1;
        let b = a + 2;
        b
    }
}
