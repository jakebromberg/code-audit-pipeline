use serde::Serialize;

/// `Serialize` derive survives; `impl` blocks add `ClassificationLabel` and
/// `Display` (last segment of `std::fmt::Display`). `Debug`/`Clone` denylisted.
#[derive(Debug, Clone, Serialize)]
pub struct BranchScanResult {
    pub repos: Vec<String>,
    pub total: usize,
}

impl ClassificationLabel for BranchScanResult {
    fn priority(&self) -> u8 {
        0
    }
    fn label(&self) -> &'static str {
        "scan"
    }
}

impl std::fmt::Display for BranchScanResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "scan")
    }
}

/// Production type whose ONLY `DataSource` conformance comes from a
/// `#[cfg(test)]` impl (a test-double). That edge must NOT leak into the
/// production `conforms_to` — it doesn't exist in release builds.
pub struct ProductionClient {
    pub endpoint: String,
}

#[cfg(test)]
impl DataSource for ProductionClient {
    fn load(&self) -> Vec<u8> {
        Vec::new()
    }
}
