/// Every derive is on the std-derive denylist → `conforms_to` stays empty.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct PlainCounts {
    pub a: usize,
    pub b: usize,
}
