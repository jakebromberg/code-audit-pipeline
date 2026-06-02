// Relative import whose target does not exist. Resolver should fail to
// probe; the spec is preserved verbatim with package: "extern".
import { Mystery } from './does-not-exist';

export const used: typeof Mystery = null as never;
