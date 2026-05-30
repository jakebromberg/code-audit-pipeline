// Smoke-test fixture for type-catalog.mjs. Names are deliberately distinct so
// the presence assertions can't collide. Pairs with secondary.ts so the
// determinism guard exercises inter-file ordering, not just a single file.
//
// Covered shapes (this file):
//   - plain interface w/ self-reference -> FlowsheetEntry     (kind: interface, references: [{name: "FlowsheetEntry", kind: "type-ref"}])
//   - Zod schema                        -> ListenerSchema     (kind: zod-object, fields populated)
//   - Drizzle table                     -> stations           (kind: drizzle-table, db_table_name: "stations")
//   - generic type alias                -> PageEnvelope       (kind: type-alias-object, generics)
//
// End-to-end behavior is covered by the node:test suite under
// extractors/typescript/test/. This file exercises the AST walker in a CI
// step that asserts contract conformance.

import { z } from 'zod';
import { pgTable, integer, text } from 'drizzle-orm/pg-core';

export interface FlowsheetEntry {
  id: number;
  artist_name: string | null;
  album_title: string | null;
  previous_entry: FlowsheetEntry | null;
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
