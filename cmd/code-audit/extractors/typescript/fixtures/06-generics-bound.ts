// Fixture: generic interface with a bound. Type parameter T is in scope, so
// the field `items: T[]` should NOT produce a reference to T. The bound `Item`
// IS a reference (declared at module scope).
// Expected: Box.references = [{name: "Item", kind: "type-ref"}].
// The bound `T extends Item` adds `Item` once; `meta: Item` adds it again →
// deduplication collapses to one entry.

export interface Item {
  id: string;
}

export interface Box<T extends Item> {
  items: T[];
  meta: Item;
}
