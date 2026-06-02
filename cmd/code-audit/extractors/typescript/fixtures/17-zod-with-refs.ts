// Fixture: zod-object — best-effort for v1. References walking inside a
// builder-DSL chain (z.object({...}).extend({...})) is out of scope. v1
// emits empty `references` for zod records; future work may improve recall.
// Expected: UserSchema.references = [] (kind == "zod-object").

import { z } from 'zod';

export const UserSchema = z.object({
  id: z.number(),
  name: z.string(),
});
