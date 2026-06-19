//! Free functions: plain (long body), async, generic (T excluded from refs),
//! and a short body that gates body fields to null.

use std::collections::HashMap;

pub struct Widget;
pub struct Gadget;

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

/// Private free fn -> exported = false.
fn private_helper(map: HashMap<String, usize>) -> usize {
    map.len()
}
