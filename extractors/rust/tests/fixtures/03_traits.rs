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
