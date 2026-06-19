//! CLI front-end for rust-catalog.
//!
//!   rust-catalog type --root <path> [--shared <path>] [--touched <json>]
//!                     [--output <path>] [--include-tests]
//!   rust-catalog func --root <path> [--shared <path>] [--touched <json>]
//!                     [--output <path>] [--include-tests] [--min-body-lines <n>]
//!
//! A `type` or `func` subcommand is required (matching the Swift extractor's
//! shape; `package-graph` may follow). Catalog JSON goes to `--output` or
//! stdout; summary stats and diagnostics go to stderr.

use std::path::PathBuf;
use std::process::exit;

use rust_catalog::{run, run_func, Args};

const USAGE: &str = "usage: rust-catalog <type|func> --root <path> [--shared <path>] [--touched <json>] [--output <path>] [--include-tests] [--min-body-lines <n>]";

enum Cmd {
    Type,
    Func,
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    match parse(&argv[1..]) {
        Ok((Cmd::Type, args)) => exit(run(&args)),
        Ok((Cmd::Func, args)) => exit(run_func(&args)),
        Err(msg) => {
            eprintln!("error: {msg}");
            eprintln!("{USAGE}");
            exit(2);
        }
    }
}

fn parse(args: &[String]) -> Result<(Cmd, Args), String> {
    let mut it = args.iter();
    let sub = it
        .next()
        .ok_or("missing subcommand (expected `type` or `func`)")?;
    let cmd = match sub.as_str() {
        "type" => Cmd::Type,
        "func" => Cmd::Func,
        other => {
            return Err(format!(
                "unknown subcommand `{other}` (expected `type` or `func`)"
            ))
        }
    };

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
            // `func` only; harmless on `type` (which ignores it).
            "--min-body-lines" => {
                out.min_body_lines = req(&mut it, "--min-body-lines")?
                    .parse()
                    .map_err(|_| "--min-body-lines requires a non-negative integer".to_string())?;
            }
            other => return Err(format!("unknown argument `{other}`")),
        }
    }
    if !have_root {
        return Err("--root is required".into());
    }
    Ok((cmd, out))
}

fn req(it: &mut std::slice::Iter<String>, flag: &str) -> Result<String, String> {
    it.next()
        .cloned()
        .ok_or_else(|| format!("{flag} requires a value"))
}
