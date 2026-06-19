use std::collections::HashMap;

/// Alias to a container — only `BranchInfo` survives the builtin denylist.
pub type RepoMap = HashMap<String, Vec<BranchInfo>>;

/// Generic alias — `T` excluded; `Error` survives.
pub type Handler<T> = fn(T) -> Result<(), Error>;
