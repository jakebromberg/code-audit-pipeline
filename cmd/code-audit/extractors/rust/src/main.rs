//! CLI front-end for rust-catalog.
//!
//!   rust-catalog type --root <path> [--shared <path>] [--touched <json>]
//!                     [--output <path>] [--include-tests]
//!
//! A `type` subcommand is required (leaving room for `func` / `package-graph`
//! later, matching the Swift extractor's shape). Catalog JSON goes to
//! `--output` or stdout; summary stats and diagnostics go to stderr.

use std::path::PathBuf;
use std::process::exit;

use rust_catalog::{run, Args};

const USAGE: &str =
    "usage: rust-catalog type --root <path> [--shared <path>] [--touched <json>] [--output <path>] [--include-tests]";

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    match parse(&argv[1..]) {
        Ok(args) => exit(run(&args)),
        Err(msg) => {
            eprintln!("error: {msg}");
            eprintln!("{USAGE}");
            exit(2);
        }
    }
}

fn parse(args: &[String]) -> Result<Args, String> {
    let mut it = args.iter();
    let sub = it.next().ok_or("missing subcommand (expected `type`)")?;
    if sub != "type" {
        return Err(format!("unknown subcommand `{sub}` (expected `type`)"));
    }

    let mut out = Args::default();
    let mut have_root = false;
    while let Some(a) = it.next() {
        match a.as_str() {
            "--root" => {
                out.root = PathBuf::from(req(&mut it, "--root")?);
                have_root = true;
            }
            "--shared" => out.shared = Some(PathBuf::from(req(&mut it, "--shared")?)),
            "--touched" => out.touched = Some(PathBuf::from(req(&mut it, "--touched")?)),
            "--output" => out.output = Some(PathBuf::from(req(&mut it, "--output")?)),
            "--include-tests" => out.include_tests = true,
            other => return Err(format!("unknown argument `{other}`")),
        }
    }
    if !have_root {
        return Err("--root is required".into());
    }
    Ok(out)
}

fn req(it: &mut std::slice::Iter<String>, flag: &str) -> Result<String, String> {
    it.next()
        .cloned()
        .ok_or_else(|| format!("{flag} requires a value"))
}
