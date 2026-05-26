// Fixture: nested generic scopes. Outer T is scoped during the outer-field
// walk; the function-type's inner T enters its own child scope. Neither T
// escapes as a reference.
// Expected: Outer.references = []  (both T's are in their respective scopes).

export interface Outer<T> {
  fn: <T>(x: T) => T;
}
