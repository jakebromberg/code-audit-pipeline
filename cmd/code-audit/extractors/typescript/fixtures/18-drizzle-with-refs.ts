// Fixture: drizzle-table — best-effort for v1. Foreign-key references inside
// the column-builder chain are runtime references, not type references; v1
// emits empty `references` for drizzle records.
// Expected: posts.references = [] (kind == "drizzle-table").

import { pgTable, integer, text } from 'drizzle-orm/pg-core';

export const posts = pgTable('posts', {
  id: integer('id').primaryKey(),
  title: text('title').notNull(),
});
