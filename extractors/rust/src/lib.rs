//! rust-catalog — `syn`-based Rust AST extractor emitting the canonical
//! `type-catalog.json` (see ../../docs/pipeline-contract.md).
//!
//! Orchestration only: walk each package root, extract per file, merge the
//! package-level `impl Trait for Type` conformance map, sort for byte
//! determinism, and write the wrapper object.

pub mod extract;
pub mod func_model;
pub mod functions;
pub mod model;
pub mod util;

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use extract::{extract_file, FileCtx, ImplMap};
use func_model::{FnCatalog, FnEntry};
use model::{Catalog, Entry, ExtractorBlock};

/// Parsed CLI inputs, shared by the `type` and `func` subcommands.
pub struct Args {
    pub root: PathBuf,
    pub shared: Option<PathBuf>,
    pub touched: Option<PathBuf>,
    pub output: Option<PathBuf>,
    /// Accepted for manifest parity. The type catalog always extracts test
    /// files and tags them `is_test`; filter downstream with jq. No-op today.
    pub include_tests: bool,
    /// `func` only: functions whose normalized body has fewer than this many
    /// lines emit null body fields. Ignored by `type`. Default 3.
    pub min_body_lines: usize,
}

impl Default for Args {
    fn default() -> Self {
        Args {
            root: PathBuf::new(),
            shared: None,
            touched: None,
            output: None,
            include_tests: false,
            min_body_lines: 3,
        }
    }
}

/// Run the extraction. Returns the process exit code (0 on success, 1 if no
/// files were indexed under `--root`).
pub fn run(args: &Args) -> i32 {
    let root = canonical(&args.root);
    let touched = read_touched(args.touched.as_deref());

    let (mut entries, main_count) = extract_package(&root, "main", &touched);
    eprintln!("main: {main_count} files");

    if let Some(shared) = &args.shared {
        let shared = canonical(shared);
        let (shared_entries, shared_count) = extract_package(&shared, "shared", &HashSet::new());
        eprintln!("shared: {shared_count} files");
        entries.extend(shared_entries);
    }

    // Stable sort: (package, file, line, name, kind) — byte-deterministic
    // output. `kind` is the final tiebreak so two items declared at the same
    // line under the same name (e.g. `struct S` and `enum S` collapsed onto one
    // line, or any same-name macro-adjacent pair) order deterministically
    // rather than relying on AST-traversal insertion order plus sort stability.
    entries.sort_by(|a, b| {
        (&a.package, &a.file, a.line, &a.name, &a.kind)
            .cmp(&(&b.package, &b.file, b.line, &b.name, &b.kind))
    });

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let total = entries.len();
    let catalog = Catalog {
        schema_version: util::SCHEMA_VERSION,
        extractor: ExtractorBlock {
            language: util::LANGUAGE,
            name: util::EXTRACTOR_NAME,
            version: util::EXTRACTOR_VERSION,
            source_sha: util::source_sha(),
        },
        fingerprint_v: util::FINGERPRINT_V,
        generated_at: util::unix_to_iso8601(now_secs),
        entries,
    };

    eprintln!("\nTotal entries: {total}");
    if !write_output(args.output.as_deref(), &catalog) {
        return 1; // a requested --output that could not be written is a failure
    }

    if main_count > 0 {
        0
    } else {
        1
    }
}

/// Extract every `.rs` file under `root`, then merge the package-level
/// `impl Trait for Type` conformance edges into each declaration by name.
fn extract_package(root: &Path, package: &str, touched: &HashSet<String>) -> (Vec<Entry>, usize) {
    let files = util::walk_rust_files(root);
    let count = files.len();
    let mut entries: Vec<Entry> = Vec::new();
    let mut impl_map: ImplMap = ImplMap::new();

    for f in &files {
        let text = match std::fs::read_to_string(f) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("  ERR read {}: {e}", f.display());
                continue;
            }
        };
        let rel = relpath(f, root);
        let ctx = FileCtx {
            package,
            rel: &rel,
            touched: package == "main" && touched.contains(&rel),
            generated: util::is_generated(&rel),
            path_is_test: util::is_test_path(&rel),
        };
        extract_file(&text, &ctx, &mut entries, &mut impl_map);
    }

    // Finalize: fold impl-derived conformance into each entry's conforms_to.
    for e in &mut entries {
        if let Some(traits) = impl_map.get(&e.name) {
            let mut set: BTreeSet<String> = e.conforms_to.iter().cloned().collect();
            set.extend(traits.iter().cloned());
            e.conforms_to = set.into_iter().collect();
        }
    }

    (entries, count)
}

/// Run the `func` extraction. Returns the process exit code (0 on success, 1 if
/// no files were indexed under `--root`). Mirrors `run` but emits the function
/// catalog (no `impl Trait for Type` conformance pass).
pub fn run_func(args: &Args) -> i32 {
    let root = canonical(&args.root);
    let touched = read_touched(args.touched.as_deref());

    let (mut entries, main_count) =
        extract_func_package(&root, "main", &touched, args.min_body_lines);
    eprintln!("main: {main_count} files");

    if let Some(shared) = &args.shared {
        let shared = canonical(shared);
        let (shared_entries, shared_count) =
            extract_func_package(&shared, "shared", &HashSet::new(), args.min_body_lines);
        eprintln!("shared: {shared_count} files");
        entries.extend(shared_entries);
    }

    // Stable sort: (package, file, line, name, kind) — byte-deterministic
    // output, matching the type catalog's total ordering (`kind` is the final
    // tiebreak for two callables sharing a line under the same qualified name).
    entries.sort_by(|a, b| {
        (&a.package, &a.file, a.line, &a.name, &a.kind)
            .cmp(&(&b.package, &b.file, b.line, &b.name, &b.kind))
    });

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let total = entries.len();
    let catalog = FnCatalog {
        schema_version: util::SCHEMA_VERSION,
        extractor: ExtractorBlock {
            language: util::LANGUAGE,
            name: util::FUNCTION_EXTRACTOR_NAME,
            version: util::EXTRACTOR_VERSION,
            source_sha: util::source_sha(),
        },
        fingerprint_v: util::FINGERPRINT_V,
        generated_at: util::unix_to_iso8601(now_secs),
        entries,
    };

    eprintln!("\nTotal entries: {total}");
    if !write_output(args.output.as_deref(), &catalog) {
        return 1; // a requested --output that could not be written is a failure
    }

    if main_count > 0 {
        0
    } else {
        1
    }
}

/// Extract every `.rs` file under `root` into function-catalog rows.
fn extract_func_package(
    root: &Path,
    package: &str,
    touched: &HashSet<String>,
    min_body_lines: usize,
) -> (Vec<FnEntry>, usize) {
    let files = util::walk_rust_files(root);
    let count = files.len();
    let mut entries: Vec<FnEntry> = Vec::new();

    for f in &files {
        let text = match std::fs::read_to_string(f) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("  ERR read {}: {e}", f.display());
                continue;
            }
        };
        let rel = relpath(f, root);
        let ctx = FileCtx {
            package,
            rel: &rel,
            touched: package == "main" && touched.contains(&rel),
            generated: util::is_generated(&rel),
            path_is_test: util::is_test_path(&rel),
        };
        functions::extract_funcs_file(&text, &ctx, min_body_lines, &mut entries);
    }

    (entries, count)
}

/// Parse the `--touched` JSON array into a set; warns and returns empty on any
/// read/parse failure. Shared by `run` and `run_func`.
fn read_touched(path: Option<&Path>) -> HashSet<String> {
    let Some(p) = path else {
        return HashSet::new();
    };
    match std::fs::read_to_string(p) {
        Ok(text) => serde_json::from_str::<Vec<String>>(&text)
            .map(|v| v.into_iter().collect())
            .unwrap_or_else(|e| {
                eprintln!("warning: could not parse --touched {}: {e}", p.display());
                HashSet::new()
            }),
        Err(e) => {
            eprintln!("warning: could not read --touched {}: {e}", p.display());
            HashSet::new()
        }
    }
}

fn canonical(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// Path of `file` relative to `root`, with `/` separators.
fn relpath(file: &Path, root: &Path) -> String {
    let rel = file.strip_prefix(root).unwrap_or(file);
    rel.to_string_lossy().replace('\\', "/")
}

/// Write the catalog to `--output` (or stdout when absent). Returns `false`
/// only when a requested `--output` path could not be written — the caller
/// turns that into a non-zero exit so a pipeline never mistakes a failed write
/// for a fresh catalog. A failed `--output` write is NOT mirrored to stdout:
/// the caller asked for a file, and dumping JSON to a stdout nobody is reading
/// would just mask the error.
fn write_output<C: serde::Serialize>(output: Option<&Path>, catalog: &C) -> bool {
    let mut text = serde_json::to_string_pretty(catalog).expect("serialize catalog");
    text.push('\n');
    match output {
        Some(path) => match std::fs::write(path, &text) {
            Ok(()) => {
                eprintln!("Wrote {}", path.display());
                true
            }
            Err(e) => {
                eprintln!("error: could not write {}: {e}", path.display());
                false
            }
        },
        None => {
            print!("{text}");
            true
        }
    }
}
