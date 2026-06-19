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

/// Trait names in `dyn`/bound positions surface as references; ubiquitous
/// markers (`Send`) and structural std traits (`Fn`, `Iterator`) are
/// denylisted, but a binding value (`Event`) and domain traits survive.
pub struct Registry {
    pub handler: Box<dyn Handler>,
    pub sink: Box<dyn Encoder + Send>,
    pub callback: Box<dyn Fn(u32) -> u32>,
    pub stream: Box<dyn Iterator<Item = Event>>,
}

/// Tuple struct.
pub struct Pair(pub String, pub usize);

/// Unit struct.
pub struct Marker;

/// Private (not exported).
struct PrivateThing {
    secret: u32,
}
