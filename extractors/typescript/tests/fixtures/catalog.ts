// Smoke-test fixture for type-catalog.mjs. Exercises the five declaration
// shapes the CI smoke test asserts on. Names are deliberately distinct so the
// presence assertions can't collide with one another.
//
// Covered shapes:
//   - plain interface           -> FlowsheetEntry        (kind: interface)
//   - Zod schema                -> ListenerSchema        (kind: zod-object)
//   - Drizzle table             -> stations              (kind: drizzle-table)
//   - generic type alias        -> PageEnvelope          (kind: type-alias-object, generics)
//   - re-export (barrel)        -> re-exports `FlowsheetEntry` from this file
//
// The fixture is deliberately small. End-to-end behavior is covered by the
// node:test suite under extractors/typescript/test/. This file's only job is
// to exercise the AST walker in a CI step that asserts contract conformance.

import { z } from 'zod';
import { pgTable, integer, text } from 'drizzle-orm/pg-core';

export interface FlowsheetEntry {
  id: number;
  artist_name: string | null;
  album_title: string | null;
}

export const ListenerSchema = z.object({
  id: z.string(),
  joined_at: z.number(),
});

export const stations = pgTable('stations', {
  id: integer('id').primaryKey(),
  call_letters: text('call_letters').notNull(),
});

export type PageEnvelope<T> = {
  items: T[];
  cursor: string | null;
};

export { FlowsheetEntry as FlowsheetEntryRe };
