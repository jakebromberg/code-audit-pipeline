// Fixture: conditional type. v1 walks children via the default fall-through,
// so identifiers buried in extends-condition / true-branch / false-branch all
// surface. Type parameter T stays scoped.
// Expected: Cond.references = [Bound, FalseBranch, TrueBranch] sorted.

export interface Bound { b: number; }
export interface TrueBranch { t: number; }
export interface FalseBranch { f: number; }

export type Cond<T> = T extends Bound ? TrueBranch : FalseBranch;
