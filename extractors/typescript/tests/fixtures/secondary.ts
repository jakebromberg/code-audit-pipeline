// Second fixture source so the determinism guard exercises inter-file ordering
// (not just a single file's source-position order). Also covers
// `type-alias-union`, a shape catalog.ts doesn't reach.

export interface ListenerProfile {
  station_id: number;
  joined_at: number;
}

export type SyncResult =
  | { ok: true; checkpoint: string }
  | { ok: false; error: string };
