// Fixture: intersection of named operands and an inline literal.
// Per spec §6.3: named operands of an intersection go into `extends`. Inline
// literals do not — they extend an anonymous shape, not a name. References
// also include the named operands (they appear in the alias body).
// Expected: Combined.extends = ["BaseA", "BaseB"].
//           Combined.references contains BaseA and BaseB (kind: type-ref).

export interface BaseA {
  a: number;
}

export interface BaseB {
  b: string;
}

export type Combined = BaseA & BaseB & { c: boolean };
