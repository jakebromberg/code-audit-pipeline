// Second fixture source so the determinism guard exercises inter-file ordering
// (not just a single file's source-position order). Also covers shapes
// catalog.ts doesn't reach: `type-alias-union`, `type-alias-intersection`,
// `type-alias-infer-model`, and a non-exported interface (exported: false).

import type { FlowsheetEntry } from './catalog';
import { stations } from './catalog';

export interface ListenerProfile {
  station_id: number;
  joined_at: number;
}

export type SyncResult =
  | { ok: true; checkpoint: string }
  | { ok: false; error: string };

// Intersection of a named ref + an inline literal — exercises the
// `type-alias-intersection` branch and the operands resolver.
export type FlowsheetEntryWithStation = FlowsheetEntry & { station_id: number };

// Modern Drizzle `typeof T.$inferSelect` — exercises the `type-alias-infer-model`
// detection path (TypeQueryNode → QualifiedName with .$inferSelect).
export type Station = typeof stations.$inferSelect;

// Non-exported declaration — pins the `exported: false` branch of exportedMod().
// Smoke-test fixtures other than this one are all exported; without this entry
// a regression that flipped the default to always-true would be invisible.
interface InternalDraftEntry {
  id: number;
  pending: boolean;
}
