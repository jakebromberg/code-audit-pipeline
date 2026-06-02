// Fixture: both legacy `InferSelectModel<typeof T>` and modern
// `typeof T.$inferSelect` forms. The Drizzle helper names themselves are in
// the deny-list (already first-class via `infer_ref`), so only the table
// identifier `usersTable` surfaces as a reference.
// Expected: LegacyUser.references = [{usersTable, type-ref}]
//           ModernUser.references = [{usersTable, type-ref}]

import { pgTable, integer } from 'drizzle-orm/pg-core';
import type { InferSelectModel } from 'drizzle-orm';

export const usersTable = pgTable('users', {
  id: integer('id').primaryKey(),
});

export type LegacyUser = InferSelectModel<typeof usersTable>;
export type ModernUser = typeof usersTable.$inferSelect;
