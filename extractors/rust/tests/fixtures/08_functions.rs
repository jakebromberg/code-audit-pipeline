//! Free functions: plain (long body), async, generic (T excluded from refs),
//! and a short body that gates body fields to null. Also exercises inline
//! generic-bound references and raw-identifier parameter names.

use std::collections::HashMap;

pub struct Widget;
pub struct Gadget;

/// A domain trait used only as an inline bound below.
pub trait DomainHandler {}

/// Inline generic BOUND -> `DomainHandler` must appear in `references` even
/// though it occurs only on the type parameter, never in a param/return type.
/// `H` (the param's type) is excluded as a generic.
pub fn run_with_handler<H: DomainHandler>(handler: H) {
    let started = true;
    let count = 0;
    let _ = handler;
    let _ = started;
    let _ = count;
}

/// Raw-identifier parameter -> `param_names` must be the semantic `type`, not
/// the lexical `r#type`.
pub fn raw_param(r#type: Widget) -> Widget {
    let held = r#type;
    let tag = 1;
    let _ = tag;
    held
}

/// Long body (>= 3 distinct normalized lines) -> body fields populated.
/// Params reference Widget (kept) and usize (builtin, dropped); returns Gadget.
pub fn assemble_widget(input: Widget, count: usize) -> Gadget {
    let mut total = count;
    total += 1;
    let doubled = total * 2;
    let _ = input;
    let _ = doubled;
    Gadget
}

/// Async free fn -> async = true.
pub async fn fetch_gadget(id: usize) -> Gadget {
    let key = id;
    let next = key + 1;
    let _ = next;
    Gadget
}

/// Generic fn -> T excluded from references; Widget survives, Vec is builtin.
pub fn wrap_in_vec<T>(item: T, seed: Widget) -> Vec<T> {
    let mut out = Vec::new();
    out.push(item);
    let _ = seed;
    out
}

/// Short body (< 3 distinct lines) -> all body fields null, row still emitted.
pub fn tiny() -> usize {
    1
}

/// Empty body -> body fields stay null even at `--min-body-lines 0` (an empty
/// body has no duplication signal; the guard stops every empty fn clustering on
/// the sha256 of the empty string).
pub fn truly_empty() {}

/// Private free fn -> exported = false.
fn private_helper(map: HashMap<String, usize>) -> usize {
    map.len()
}
