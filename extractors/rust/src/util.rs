//! Shared helpers: constants, denylists, hashing, path classification,
//! timestamp formatting, source-SHA resolution, and the file walker.
//!
//! Mirrors the responsibilities of `extractors/python/_lib.py` so the Rust
//! catalog stays byte-compatible with the canonical schema.

use std::path::{Path, PathBuf};
use std::process::Command;

use quote::ToTokens;
use sha1::{Digest, Sha1};

pub const SCHEMA_VERSION: &str = "2.0";
pub const FINGERPRINT_V: &str = "shape_sig:1";
pub const LANGUAGE: &str = "rust";
/// The catalog KIND, not the language — `extractor.name` identifies which
/// catalog produced the file (`type-catalog` vs `function-catalog` vs …),
/// while the language lives in `extractor.language`. Mirrors the contract
/// (docs/pipeline-contract.md §"Type catalog") and the Python/TS extractors,
/// which both emit `name: "type-catalog"`.
pub const EXTRACTOR_NAME: &str = "type-catalog";
pub const EXTRACTOR_VERSION: &str = "0.1.0";

/// Directories pruned on every walk. Mirrors the substrate convention in
/// docs/pipeline-contract.md §"What to skip" plus Rust's `target/` build dir
/// (NOT a dotdir, so it would otherwise be descended into).
pub const SKIP_DIRS: &[&str] = &["node_modules", "dist", "build", "coverage", "target"];

/// Universal test-path directory segments (docs/pipeline-contract.md
/// §"Test path patterns"). Rust integration tests live under `tests/`.
const TEST_DIR_SEGMENTS: &[&str] = &[
    "tests",
    "test",
    "__tests__",
    "__test__",
    "spec",
    "__mocks__",
    "__fixtures__",
    "fixtures",
    "e2e",
];

/// Universal test-filename suffixes for `.rs` sources.
const TEST_FILE_SUFFIXES: &[&str] = &[
    ".test.rs",
    ".spec.rs",
    ".fixture.rs",
    ".fixtures.rs",
    ".mock.rs",
    ".mocks.rs",
];

/// Built-in / std type names excluded from `references` so they don't dominate
/// the graph. The Rust analog of the TypeScript `BUILTIN_TYPE_DENYLIST`.
pub fn is_builtin_type(name: &str) -> bool {
    matches!(
        name,
        // primitives
        "u8" | "u16" | "u32" | "u64" | "u128" | "usize"
            | "i8" | "i16" | "i32" | "i64" | "i128" | "isize"
            | "f32" | "f64" | "bool" | "char" | "str" | "String"
            // ubiquitous std containers / smart pointers
            | "Vec" | "Option" | "Result" | "Box" | "Rc" | "Arc" | "Cell"
            | "RefCell" | "Mutex" | "RwLock" | "Cow"
            | "HashMap" | "HashSet" | "BTreeMap" | "BTreeSet" | "VecDeque"
            | "PathBuf" | "Path" | "OsString" | "OsStr" | "CString" | "CStr"
            // common std markers / aliases seen in signatures
            | "Self" | "Sized"
            // ubiquitous std *traits* seen in dyn/impl/bound positions — these
            // are structural, never domain types, so they must not flood the
            // reference graph when collected from trait bounds. (Marker derives
            // like Send/Sync/Clone are filtered separately via is_std_derive.)
            | "Fn" | "FnMut" | "FnOnce"
            | "Iterator" | "IntoIterator" | "DoubleEndedIterator" | "ExactSizeIterator"
            | "Future" | "IntoFuture"
            | "Into" | "From" | "TryInto" | "TryFrom"
            | "AsRef" | "AsMut" | "Borrow" | "BorrowMut" | "ToOwned"
            | "Deref" | "DerefMut" | "Any" | "Unpin"
    )
}

/// Ubiquitous derive/marker traits excluded from `conforms_to` so they don't
/// flood the already-abstracted axis. The Rust analog of Swift's
/// `PROTOCOL_LIKE_INHERITED`. Meaningful derives (Serialize, domain traits)
/// survive. Edit this single list to tune the axis.
pub fn is_std_derive(name: &str) -> bool {
    matches!(
        name,
        "Debug"
            | "Clone"
            | "Copy"
            | "Default"
            | "PartialEq"
            | "Eq"
            | "PartialOrd"
            | "Ord"
            | "Hash"
            | "Send"
            | "Sync"
            | "Sized"
    )
}

/// shape_sig = fields.sorted().join("|").lower() — per pipeline-contract.md.
pub fn shape_sig(fields: &[String]) -> String {
    let mut sorted = fields.to_vec();
    sorted.sort();
    sorted.join("|").to_lowercase()
}

/// Render a syn type node to normalized source text: token-stream spelling
/// with whitespace tightened around punctuation. Deterministic and applied
/// consistently, so shape clustering is unaffected by the exact spacing.
pub fn normalize_type(ty: &syn::Type) -> String {
    normalize_tokens(&ty.to_token_stream().to_string())
}

/// Same normalization for any `ToTokens` node (used for type aliases).
pub fn normalize_token_string(raw: &str) -> String {
    normalize_tokens(raw)
}

fn normalize_tokens(raw: &str) -> String {
    let mut s = raw.to_string();
    // Tighten spacing the proc-macro2 token printer inserts. Order-insensitive
    // pairs applied repeatedly until stable enough for display purposes.
    for _ in 0..3 {
        for (from, to) in [
            (" <", "<"),
            ("< ", "<"),
            (" >", ">"),
            (" ::", "::"),
            (":: ", "::"),
            (" :", ":"), // tighten `x : T` -> `x:T` in struct-variant fields
            (" ,", ","),
            (" ;", ";"),
            ("& ", "&"),
            ("( ", "("),
            (" )", ")"),
            ("[ ", "["),
            (" ]", "]"),
            (" !", "!"),
        ] {
            s = s.replace(from, to);
        }
    }
    // Collapse any remaining whitespace runs to single spaces, trim.
    let collapsed: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed.trim().to_string()
}

/// Path-based test-file classification. Mirrors the universal contract; the
/// AST-based `#[cfg(test)]` extension is handled separately in extract.rs.
pub fn is_test_path(rel: &str) -> bool {
    let parts: Vec<&str> = rel.split('/').collect();
    if let Some((_, dirs)) = parts.split_last() {
        for seg in dirs {
            if TEST_DIR_SEGMENTS.contains(seg) {
                return true;
            }
        }
    }
    let filename = parts.last().copied().unwrap_or("");
    TEST_FILE_SUFFIXES.iter().any(|suf| filename.ends_with(suf))
}

/// File-path-derived generated flag. Any `generated/` path segment flips it.
pub fn is_generated(rel: &str) -> bool {
    rel.starts_with("generated/") || rel.contains("/generated/")
}

/// sha1 over (package, file, name, kind) joined by NUL bytes, lowercase hex.
pub fn symbol_id(package: &str, file: &str, name: &str, kind: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(format!("{package}\0{file}\0{name}\0{kind}").as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Resolve the SHA of the extractor's *source tree*, mirroring
/// `_lib.compute_source_sha`: anchor at the extractor's own directory (the
/// compile-time `CARGO_MANIFEST_DIR` — the Rust analog of Python's `__file__`),
/// walk up to the first ancestor that is a git repo root (its
/// `git rev-parse --show-toplevel` equals itself), and return that repo's HEAD.
/// Stops at `$HOME` or the filesystem root.
///
/// Anchoring at the source dir rather than the process CWD is what makes the
/// value mean "which extractor build produced this catalog," independent of
/// where the binary is invoked from; the `--show-toplevel == dir` guard keeps
/// an unrelated *enclosing* repo's HEAD from being misattributed. Returns
/// "unknown" (with a stderr warning) when the source tree is not in a git
/// checkout (e.g. the embed-extracted, laid-down layout).
pub fn source_sha() -> String {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|h| std::fs::canonicalize(&h).unwrap_or(h));
    let start = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut cur = std::fs::canonicalize(&start).unwrap_or(start);
    for _ in 0..16 {
        if home.as_deref() == Some(cur.as_path()) {
            break;
        }
        if let Some(sha) = git_head_if_toplevel(&cur) {
            return sha;
        }
        match cur.parent() {
            Some(p) if p != cur => cur = p.to_path_buf(),
            _ => break,
        }
    }
    eprintln!(
        "warning: extractor source not in a git checkout; source_sha recorded as \"unknown\""
    );
    "unknown".to_string()
}

/// HEAD SHA of the git repo rooted *exactly* at `dir`, or `None` if `dir` is
/// not itself a repo top-level (or git is unavailable). The `--show-toplevel`
/// equality check is what prevents attributing an enclosing repo's HEAD to the
/// extractor when its source dir is nested inside an unrelated checkout.
fn git_head_if_toplevel(dir: &Path) -> Option<String> {
    let top = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .ok()?;
    if !top.status.success() {
        return None;
    }
    let top_path = PathBuf::from(String::from_utf8_lossy(&top.stdout).trim());
    let top_path = std::fs::canonicalize(&top_path).unwrap_or(top_path);
    if top_path != *dir {
        return None;
    }
    let head = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(dir)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .ok()?;
    if !head.status.success() {
        return None;
    }
    let sha = String::from_utf8_lossy(&head.stdout).trim().to_string();
    (sha.len() == 40 && sha.bytes().all(|b| b.is_ascii_hexdigit())).then_some(sha)
}

/// Format Unix seconds as ISO-8601 UTC (`YYYY-MM-DDThh:mm:ssZ`), dependency-free.
/// Uses Howard Hinnant's days-from-civil algorithm.
pub fn unix_to_iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);

    // days since 1970-01-01 -> civil (y, m, d)
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };

    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

/// Yield every `.rs` file under `root`, pruning dotdirs and SKIP_DIRS in place
/// so we never descend into worktree clones or build output.
pub fn walk_rust_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let ft = match entry.file_type() {
                Ok(t) => t,
                Err(_) => continue,
            };
            if ft.is_dir() {
                if name.starts_with('.') || SKIP_DIRS.contains(&name.as_ref()) {
                    continue;
                }
                stack.push(path);
            } else if ft.is_file() && name.ends_with(".rs") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shape_sig_is_sorted_and_lowercased() {
        let f = vec!["b:Int".to_string(), "a:String".to_string()];
        assert_eq!(shape_sig(&f), "a:string|b:int");
    }

    #[test]
    fn test_path_matches_dirs_and_suffixes() {
        assert!(is_test_path("crates/foo/tests/integration.rs"));
        assert!(is_test_path("src/widget.test.rs"));
        assert!(!is_test_path("src/types.rs"));
        assert!(!is_test_path("src/testutil.rs")); // not a test segment/suffix
    }

    #[test]
    fn builtin_and_derive_denylists() {
        assert!(is_builtin_type("Vec"));
        assert!(is_builtin_type("usize"));
        assert!(!is_builtin_type("Classification"));
        assert!(is_std_derive("Debug"));
        assert!(!is_std_derive("Serialize"));
    }

    #[test]
    fn iso8601_epoch_and_known_instants() {
        assert_eq!(unix_to_iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(unix_to_iso8601(1_000_000_000), "2001-09-09T01:46:40Z");
        assert_eq!(unix_to_iso8601(1_700_000_000), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn normalize_tightens_generics() {
        let ty: syn::Type = syn::parse_str("Vec<Option<String>>").unwrap();
        assert_eq!(normalize_type(&ty), "Vec<Option<String>>");
    }
}
