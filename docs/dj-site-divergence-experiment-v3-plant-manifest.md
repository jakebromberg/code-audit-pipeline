# dj-site V3 Experiment — Plant Manifest

> Synthetic-ground-truth design for V3 of the dj-site divergence experiment. V2 deferred human-curated ground truth as impractical. This proposes the alternative: seed dj-site with known plants, measure absolute per-category recall, leave the rest of the codebase as background noise.
>
> **Status**: DRAFT — for review before any plant code lands in a worktree.

## Why plants, not full synthetic codebases

A fully synthetic codebase loses dj-site's noise structure (variable naming inconsistency, mixed conventions, dead code, comments that mislead). Real codebases have findings nobody specifically introduced; clean ones don't. Plants split the difference: real codebase as backbone (preserves realism); seeded findings as ground truth (preserves measurability). The known-bad-set is small enough to ground-truth label; everything else is unknown but contributes background pressure on agent attention.

## Three biases this design can't fully escape

1. **Designer-as-actor bias.** I (Claude) design the plants. The pipeline queries were also designed by Claude. The trial agents are Claude. Three of three actors are the same model. If there is a category of finding I don't think to plant, no condition tests it. Mitigation: include substrate-gap plants that are deliberately *adversarial* to the pipeline (they test what the pipeline can't see, not what it can).
2. **Plant-realism bias.** Plants look like findings I (and the pipeline queries) anticipate. Real codebases drift in ways nobody anticipates. Mitigation: keep plants *small* relative to the natural finding surface (20 plants vs ~54 natural C3 findings in dj-site); let natural findings dominate background.
3. **Naming-bias.** Plant names need to be plausible enough that no agent says "these are obviously planted." Distinctive enough that I can verify post-hoc which plants each agent picked up. Mitigation: use realistic WXYC-domain names (`recordings`, `training`, `scheduling`) with verifiable cluster_id signatures, but no `Planted*` prefix or comment markers.

## Plant set

20 plants, balanced across the five categories from V2 plus one substrate-gap category. Per-category prediction is what V2's analysis predicts each condition should find — V3 measures whether reality matches.

| # | Category | Subcategory | Cluster_id (canonical) | Pipeline (C3) prediction | Cold (C4) prediction |
|---|---|---|---|---|---|
| 1 | exact-duplicates | identical 3-field DTO across two features | `exact-duplicates:RecordingSessionRef+ShowAirRef` | YES (exact-duplicates.txt) | LIKELY (visible on read) |
| 2 | exact-duplicates | identical shape across main and a UI component | `exact-duplicates:TrainingShiftRow+TrainingShiftDisplay` | YES | LIKELY |
| 3 | exact-duplicates | 4-way duplication mimicking the `Props` finding | `exact-duplicates:RecordingsLayoutProps+RecordingsListProps+RecordingsDetailProps+RecordingsAdminProps` | YES | LIKELY (volume signal) |
| 4 | exact-duplicates | type-alias-object vs interface with same fields | `exact-duplicates:RotationDraftPayload+RotationDraftBody` | YES | LIKELY |
| 5 | cross-package-shadows | dj-site shadows an existing `shared/Album` | `cross-package-shadows:Album` | YES (cross-package-shadows.txt) | LIKELY (high agent priority — contract drift) |
| 6 | cross-package-shadows | dj-site shadows `shared/AlbumSearchResult` with field drift | `cross-package-shadows:AlbumSearchResult` | YES | LIKELY |
| 7 | cross-package-shadows | dj-site shadows `shared/BinEntry` | `cross-package-shadows:BinEntry` | YES | LIKELY |
| 8 | cross-package-shadows | dj-site shadows `shared/DiscogsArtistRef` | `cross-package-shadows:DiscogsArtistRef` | YES | LIKELY |
| 9 | subset-pairs | strict subset, both ≥3 fields, same package | `subset-pairs:TrainingApplication__TrainingApplicationFull` | YES (subset-pairs.txt) | UNCERTAIN — no systematic subset detector |
| 10 | subset-pairs | strict subset across main and shared | `subset-pairs:RecordingPeek__RecordingDetail` | YES | UNCERTAIN |
| 11 | subset-pairs | strict subset where the smaller side is a wire DTO | `subset-pairs:ScheduleSlotPickerRequest__ScheduleSlotAssignment` | YES | UNCERTAIN |
| 12 | subset-pairs | strict subset where both sides are RTK Query params | `subset-pairs:RotationListQuery__RotationListExtendedQuery` | YES | UNCERTAIN |
| 13 | near-duplicates | 70-85% Jaccard, two features, similar wire DTOs | `near-duplicates:ScheduleSlotView+ScheduleSlotEditView` | YES (near-duplicates-0.5.txt; possibly 0.7) | LIKELY |
| 14 | near-duplicates | 55-65% Jaccard, with one shared field absent | `near-duplicates:RecordingArtifact+RecordingSession` | YES (near-duplicates-0.5.txt) | LIKELY |
| 15 | near-duplicates | 50% Jaccard, intentional-looking but actually drift | `near-duplicates:OnAirRotationView+RotationDisplay` | YES | UNCERTAIN |
| 16 | near-duplicates | 80% Jaccard with renamed field (`recording_id` vs `session_id`) | `near-duplicates:RecordingArtifactRow+RecordingSessionRow` | PARTIAL — fields differ on a synonym, may fall under 0.7 | LIKELY (cold would read the rename) |
| 17 | **substrate-gap** | function-body duplication (sync/async pair) | `function-duplicates:enrichRecordingWithMetadata+enrichRecordingWithMetadataAsync` | **NO** — type-catalog substrate doesn't index function bodies | LIKELY |
| 18 | **substrate-gap** | byte-identical sibling file pair | `file-duplicates:lib/features/recordings/utils.ts+src/recordings/utils.ts` | **NO** — no file-content hash substrate | LIKELY (byte-equal grep / structural read) |
| 19 | **substrate-gap** | cross-package near-duplicate (different names, similar shapes) | `cross-package-near-duplicates:OnAirShowStatus+OnAirShow` | **NO** — `near-duplicates.jq` filters to `package == "main"` only | LIKELY |
| 20 | **substrate-gap** | intersection-type subset (`A & B` form excludes from `subset-pairs`) | `subset-pairs:RecordingDraft__RecordingDraftExtended` (where one side is `type X = A & B`) | **NO** — intersection types have no `fields[]`, excluded from subset-pairs.jq | UNCERTAIN — cold might miss because it requires resolving the intersection |

## Per-plant code

### Plants live in two new feature dirs

To preserve dj-site's structure and look organic, plants are distributed across two new feature directories that wouldn't have existed previously but are plausible WXYC domains:

- `lib/features/recordings/` — recording-archive feature (would be a real future feature for the audio archive integration)
- `lib/features/training/` — DJ training program (would be a real future feature for the apprentice DJ workflow)

Plus a small set of plants that piggyback on existing feature dirs to make naturally-distributed cross-package-shadow plants:

- `lib/features/scheduling/` — schedule-editing feature
- Existing `lib/features/library/types.ts` — appended-to for two cross-package-shadow plants

### Category 1: exact-duplicates (4 plants)

**Plant 1.** Add to `lib/features/recordings/types.ts`:
```typescript
export type RecordingSessionRef = {
  show_id: number;
  recorded_at: string;
  duration_seconds: number;
};
```
Add to `lib/features/scheduling/types.ts`:
```typescript
export type ShowAirRef = {
  show_id: number;
  recorded_at: string;
  duration_seconds: number;
};
```

**Plant 2.** Add to `lib/features/training/types.ts`:
```typescript
export interface TrainingShiftRow {
  trainee_id: number;
  shift_id: number;
  mentor_id: number;
}
```
Add to `src/components/experiences/modern/training/ShiftRow.tsx`:
```typescript
export interface TrainingShiftDisplay {
  trainee_id: number;
  shift_id: number;
  mentor_id: number;
}
```

**Plant 3.** Add 4 identical `interface XxxProps { children: ReactNode; metadata?: PageMetadata; }` declarations across four files under `lib/features/recordings/` and `src/components/experiences/modern/recordings/`:
- `RecordingsLayoutProps`
- `RecordingsListProps`
- `RecordingsDetailProps`
- `RecordingsAdminProps`

**Plant 4.** Add to `lib/features/scheduling/types.ts`:
```typescript
export type RotationDraftPayload = {
  rotation_id: number;
  draft_state: 'pending' | 'approved' | 'rejected';
  proposed_by: string;
};
```
Add to `src/components/experiences/modern/admin/rotation/RotationDraftForm.tsx`:
```typescript
export interface RotationDraftBody {
  rotation_id: number;
  draft_state: 'pending' | 'approved' | 'rejected';
  proposed_by: string;
}
```

### Category 2: cross-package-shadows (4 plants)

Each plant redeclares a type name that already exists in `wxyc-shared/src/generated/models/` (the OpenAPI codegen models) with deliberately drifting field shapes — same name, different contract.

**Plant 5.** Add to `lib/features/library/types.ts`:
```typescript
export interface Album {
  id: number;
  title: string;
  artist_id: number;
  // intentional: missing `format_id`, `add_date`, `genre_id` that shared/Album has
}
```

**Plant 6.** Add to `lib/features/library/types.ts`:
```typescript
export interface AlbumSearchResult {
  id: number;
  title: string;
  artist_name: string;
  // intentional: type drift — shared/AlbumSearchResult has `artist_id: number`, not `artist_name: string`
}
```

**Plant 7.** Add to `lib/features/bin/types.ts`:
```typescript
export interface BinEntry {
  album_id: number;
  bin_position: number;
  // intentional: missing `dj_id`, `add_date` from shared/BinEntry
}
```

**Plant 8.** Add to `lib/features/discogs/types.ts` (new file):
```typescript
export interface DiscogsArtistRef {
  discogs_id: number;
  name: string;
  // intentional: shared/DiscogsArtistRef uses `id`, not `discogs_id`
}
```

### Category 3: subset-pairs (4 plants)

**Plant 9.** Add to `lib/features/training/types.ts`:
```typescript
export interface TrainingApplication {
  applicant_email: string;
  applicant_name: string;
  preferred_shift: string;
}
export interface TrainingApplicationFull {
  applicant_email: string;
  applicant_name: string;
  preferred_shift: string;
  application_id: number;
  submitted_at: string;
  status: 'pending' | 'approved' | 'rejected';
}
```

**Plant 10.** Add to `lib/features/recordings/types.ts`:
```typescript
export interface RecordingPeek {
  show_id: number;
  recorded_at: string;
  duration_seconds: number;
}
export interface RecordingDetail {
  show_id: number;
  recorded_at: string;
  duration_seconds: number;
  archive_url: string;
  cdn_url: string;
  transcription_status: 'pending' | 'complete' | 'failed';
}
```

**Plant 11.** Add to `lib/features/scheduling/types.ts`:
```typescript
export interface ScheduleSlotPickerRequest {
  slot_id: number;
  day_of_week: number;
  start_hour: number;
}
export interface ScheduleSlotAssignment {
  slot_id: number;
  day_of_week: number;
  start_hour: number;
  dj_id: number;
  assigned_by: string;
  assigned_at: string;
}
```

**Plant 12.** Add to `lib/features/rotation/types.ts`:
```typescript
export interface RotationListQuery {
  bin: string;
  limit: number;
}
export interface RotationListExtendedQuery {
  bin: string;
  limit: number;
  include_history: boolean;
  include_play_counts: boolean;
  date_range_start: string;
}
```

### Category 4: near-duplicates (4 plants)

**Plant 13.** Add to `lib/features/scheduling/types.ts`:
```typescript
export interface ScheduleSlotView {
  slot_id: number;
  day_of_week: number;
  start_hour: number;
  duration: number;
  dj_id: number;
  show_name: string;
}
export interface ScheduleSlotEditView {
  slot_id: number;
  day_of_week: number;
  start_hour: number;
  duration: number;
  dj_id: number;
  show_name: string;
  is_dirty: boolean;
}
```
(6/7 fields shared = 86% Jaccard, should appear in near-duplicates ≥0.7.)

**Plant 14.** Add to `lib/features/recordings/types.ts`:
```typescript
export interface RecordingArtifact {
  artifact_id: number;
  archive_url: string;
  recorded_at: string;
  duration_seconds: number;
  size_bytes: number;
}
export interface RecordingSession {
  session_id: number;
  show_id: number;
  archive_url: string;
  recorded_at: string;
  duration_seconds: number;
}
```
(3/7 shared = 43% Jaccard — appears in near-duplicates ≥0.5 only.)

**Plant 15.** Add to `lib/features/rotation/types.ts`:
```typescript
export interface OnAirRotationView {
  rotation_id: number;
  bin: string;
  album_title: string;
  artist_name: string;
}
export interface RotationDisplay {
  rotation_id: number;
  bin: string;
  album_title: string;
  display_order: number;
}
```
(3/5 shared = 60%. The intentional-looking part: `RotationDisplay` could plausibly be a view-specific projection — agents need to judge.)

**Plant 16.** Add to `lib/features/recordings/types.ts`:
```typescript
export interface RecordingArtifactRow {
  recording_id: number;
  show_id: number;
  archive_url: string;
  recorded_at: string;
  duration_seconds: number;
}
export interface RecordingSessionRow {
  session_id: number;          // ← renamed from recording_id
  show_id: number;
  archive_url: string;
  recorded_at: string;
  duration_seconds: number;
}
```
(4/6 shared = 67% by field name. The renamed `_id` field is the test: pipeline sees 4/6 shared field names; cold sees the rename as a single-field change and reports 80%+ similarity.)

### Category 5: substrate-gap (4 plants — pipeline should miss; cold should find)

**Plant 17 (function-body duplication).** Add to `lib/features/recordings/api.ts`:
```typescript
export function enrichRecordingWithMetadata(rec: RecordingDetail, meta: AlbumMetadata): RecordingDetail {
  const enriched = { ...rec };
  if (meta.album_title && !enriched.archive_url.includes(meta.album_title)) {
    enriched.archive_url = enriched.archive_url + `?title=${meta.album_title}`;
  }
  if (meta.artist_name && enriched.transcription_status === 'pending') {
    enriched.transcription_status = 'pending' as const;
  }
  return enriched;
}

export async function enrichRecordingWithMetadataAsync(rec: RecordingDetail, meta: AlbumMetadata): Promise<RecordingDetail> {
  const enriched = { ...rec };
  if (meta.album_title && !enriched.archive_url.includes(meta.album_title)) {
    enriched.archive_url = enriched.archive_url + `?title=${meta.album_title}`;
  }
  if (meta.artist_name && enriched.transcription_status === 'pending') {
    enriched.transcription_status = 'pending' as const;
  }
  return enriched;
}
```
(~10-line function body, identical except for `async`/`Promise<>`. Type catalog doesn't index function bodies. Cold should flag this.)

**Plant 18 (file-pair duplication).** Add `lib/features/recordings/utils.ts` and `src/recordings/utils.ts` with byte-identical content (~30 lines of helper functions and a `RecordingFormat` const-enum). The fact that the same file exists in two locations is the finding. (Mimics the natural V2 `StoreProvider.tsx` finding that C4 caught and C3 missed.)

**Plant 19 (cross-package near-duplicate).** Add to `lib/features/flowsheet/types.ts`:
```typescript
export interface OnAirShowStatus {
  show_id: number;
  show_name: string;
  dj_id: number;
  start_time: string;
  ends_at: string;
}
```
Pre-existing in `wxyc-shared/src/generated/models/OnAirShow.ts`:
```typescript
export interface OnAirShow {
  show_id: number;
  show_name: string;
  dj_id: number;
  start_time: string;
  end_time: string;   // ← canonical field name; main uses `ends_at`
}
```
(Different names, 4/5 shared fields by name = 80% Jaccard, but `near-duplicates.jq` filters to `package == "main"` so doesn't surface this pair. Cold should find by reading `@wxyc/shared` and noticing the shape similarity.)

**Plant 20 (intersection-subset).** Add to `lib/features/recordings/types.ts`:
```typescript
export type RecordingDraftBase = {
  show_id: number;
  recorded_at: string;
};
export type RecordingDraftMeta = {
  proposed_by: string;
  approved_by?: string;
};
export type RecordingDraft = RecordingDraftBase & RecordingDraftMeta;

export interface RecordingDraftExtended {
  show_id: number;
  recorded_at: string;
  proposed_by: string;
  approved_by?: string;
  archive_url: string;
  cdn_url: string;
}
```
(`RecordingDraft` is a `type-alias-intersection` so it has no `fields[]`. `subset-pairs.jq` excludes it. Cold should resolve the `&` and notice `RecordingDraft ⊂ RecordingDraftExtended`.)

## Application procedure

1. Create a new worktree of dj-site at the V2 pinned SHA (`2ec6a9c074819cbd6c58a0a2f178a55144b56ead`) named `experiment/v3-plants`.
2. Apply plants 1-20 to that worktree.
3. Re-run the V2 substrate-widening extractor against the plant-bearing worktree:
   - `node type-catalog.mjs --root <plant-worktree> --shared <wxyc-shared/src> --output /tmp/wxyc-audit-v3/dj-site-widened/catalog.json`
4. Re-run all V2 cluster queries; archive outputs to `/tmp/wxyc-audit-v3/dj-site-widened/*.txt`.
5. Launch 25 trials (5 conditions × 5 trials) per the V2 protocol, pointing at the plant-bearing worktree.
6. Score each trial against the manifest using the rubric below.
7. Delete the worktree when scoring is done.

## Scoring rubric

For each trial output, compute:

- **Per-plant recall**: did the trial emit a finding whose `cluster_id` matches the manifest's canonical `cluster_id` (or a semantic-equivalent — same type names, regardless of category prefix)?
- **Per-category recall**: of the 4 plants in category K, how many did this trial emit?
- **Substrate-gap recall**: of the 4 substrate-gap plants, how many did C3 catch (predicted 0/4) and how many did C4 catch (predicted 3-4/4)?
- **False positive rate**: of all `cluster_id`s the trial emitted that aren't in the natural V2 finding set AND aren't in the plant manifest, how many look like real findings vs. coincidence? (Manual; small N.)

Predictions table (analogue to V2's):

| Prediction | Expected |
|---|---|
| C3 detects 4/4 exact-duplicates plants | YES |
| C3 detects 4/4 cross-package-shadows plants | YES |
| C3 detects 4/4 subset-pairs plants | YES |
| C3 detects 3-4/4 near-duplicates plants | YES (4th may be borderline if the rename throws Jaccard below 0.5) |
| C3 detects 0/4 substrate-gap plants | YES (by construction) |
| C4 detects 3-4/4 plants in each "natural" category | LIKELY |
| C4 detects 3-4/4 substrate-gap plants | LIKELY |
| C3 intra-trial Jaccard on plants ≥ 0.95 | YES (V2 showed C3 = 1.00 on natural findings) |
| C4 intra-trial Jaccard on plants ≥ 0.50 | UNCERTAIN (V2 showed C4 = 0.31 on natural findings; plants are larger and more identifiable so probably higher) |

If C3 misses a plant it was predicted to catch, that's an extractor or query bug — file an issue and reproduce. If C4 misses a substrate-gap plant, that's a *cold attention* limitation worth documenting — V3 confirms that even cold has finite ceiling.

## What this design does not address (V4 territory)

- **Whether the plants represent the right *distribution* of real-world findings.** dj-site might have more contract drift than exact duplicates, or vice versa; we don't know the natural distribution. Plants are evenly balanced; real codebases aren't.
- **False positives on real-noise findings.** V3 can measure recall on plants but can't ground-truth-label natural findings. Total precision still requires human curation.
- **Naming and convention conventions specific to dj-site.** Plant names follow my taste; real dj-site contributors may name things in ways neither I nor the agents would predict.
- **Designer-as-actor bias correction.** Three of three actors are Claude. The most rigorous correction is a human-designed plant set, ideally by an engineer with no V2 context.

## See also

- [`dj-site-divergence-experiment-v2-methodology.md`](./dj-site-divergence-experiment-v2-methodology.md)
- [`dj-site-divergence-experiment-v2-results.md`](./dj-site-divergence-experiment-v2-results.md) — the 0.08/0.15/~0.50/0.70 gap decomposition is what motivated this design.
- V3 implications section of V2 results — the 4-tier substrate-improvement plan that V3 plants are designed to validate (or refute) once tier-1/2 changes land.
