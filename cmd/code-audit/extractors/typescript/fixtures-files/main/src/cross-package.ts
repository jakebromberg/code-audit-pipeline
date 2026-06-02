// Cross-package import to the --shared package. Resolves through ../../shared/src/canonical.
import type { CanonicalID } from '../../shared/src/canonical';

export type UseCanonical = CanonicalID;
