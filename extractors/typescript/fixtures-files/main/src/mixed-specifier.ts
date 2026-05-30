// Mixed per-specifier type modifier. v1 declaration-level isTypeOnly is false,
// even though Target itself is type-only at the specifier level. Documented limit.
import { type Target, type TargetMeta } from './target';

export type Combo = Target & TargetMeta;
