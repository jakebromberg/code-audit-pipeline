use std::collections::HashMap;
use std::path::PathBuf;

/// Named struct: optional field, a domain reference, generics-free.
pub struct BranchInfo {
    pub repo_path: PathBuf,
    pub name: String,
    pub classification: Classification,
    pub upstream: Option<String>,
    pub counts: HashMap<String, usize>,
}

/// Generic struct — `T` must be excluded from references.
pub struct Wrapper<T> {
    pub inner: T,
    pub label: String,
}

/// Tuple struct.
pub struct Pair(pub String, pub usize);

/// Unit struct.
pub struct Marker;

/// Private (not exported).
struct PrivateThing {
    secret: u32,
}
