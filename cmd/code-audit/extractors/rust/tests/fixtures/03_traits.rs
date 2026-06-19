/// Plain trait — interface kind, no supertraits.
pub trait ClassificationLabel {
    fn priority(&self) -> u8;
    fn label(&self) -> &'static str;
}

/// Trait with supertraits: `ClassificationLabel` is meaningful conformance,
/// `Send` is denylisted away.
pub trait Reportable: ClassificationLabel + Send {
    fn report(&self, ctx: &ReportCtx) -> Summary;
}

/// Method-level generic `T` (a per-method scope) and the `Self::Item`
/// projection must NOT appear in `references` — only the external `Id` does.
pub trait Repository {
    type Item;
    fn save<T>(&self, value: T) -> T;
    fn fetch(&self, id: Id) -> Self::Item;
}

/// An external type sharing a name with an associated type must still be a
/// reference: only the `Self::Item` projection is dropped (by path shape), not
/// every type named `Item`. Here `inventory::Item` survives.
pub trait Externals {
    type Item;
    fn get(&self) -> inventory::Item;
}
