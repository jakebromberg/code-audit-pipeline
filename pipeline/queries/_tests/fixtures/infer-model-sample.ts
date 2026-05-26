// Fixture for the type-catalog extractor's InferModel coverage.
// Exercises both the legacy `InferSelectModel<typeof T>` / `InferInsertModel<typeof T>`
// API and the modern `typeof T.$inferSelect` / `typeof T.$inferInsert` API.
// Consumed by test_queries_integration.sh's extractor smoke-test block.

import { pgTable, integer } from 'drizzle-orm/pg-core';
import { InferSelectModel, InferInsertModel } from 'drizzle-orm';

export const users = pgTable('users', {
  id: integer('id'),
});

export type LegacyUser    = InferSelectModel<typeof users>;
export type LegacyNewUser = InferInsertModel<typeof users>;
export type ModernUser    = typeof users.$inferSelect;
export type ModernNewUser = typeof users.$inferInsert;
