// Fixture for §6.4 TypeScript acceptance: function pairs that differ only at
// type-position identifiers should produce identical body_hash_erased while
// their body_hash values differ.
//
// makeArrayA / makeArrayB differ only at the TypeReferenceNode for UIColor vs
// NSColor. After erasure (replace the head identifier of each TypeReference
// with _T1, _T2, ... in order of first appearance), both bodies erase to the
// same normalized form.
//
// swapFoo / swapBaz cover the multi-distinct-types case: two distinct type
// identifiers per body, each independently placeholder-assigned.

// eslint-disable @typescript-eslint/no-unused-vars
// @ts-nocheck

export function makeArrayA(value: UIColor): UIColor[] {
  const copy: UIColor = value;
  const pair: UIColor[] = [copy, value];
  return pair;
}

export function makeArrayB(value: NSColor): NSColor[] {
  const copy: NSColor = value;
  const pair: NSColor[] = [copy, value];
  return pair;
}

export function swapFoo(x: Foo, y: Bar): [Bar, Foo] {
  const a: Bar = y;
  const b: Foo = x;
  return [a, b];
}

export function swapBaz(x: Baz, y: Quux): [Quux, Baz] {
  const a: Quux = y;
  const b: Baz = x;
  return [a, b];
}
