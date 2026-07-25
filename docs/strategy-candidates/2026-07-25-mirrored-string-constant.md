# Strategy candidate: mirrored string constant across types → single shared constant

- **Captured:** 2026-07-25 (PT) from wxyc-ios-64 PR #671 @ b8739b29 (branch `ot-c8-spotlight-donation-observer`)
- **Tier:** 2 (literal-catalog widened to string literals; reuses the existing `copied-literal-candidates.jq` query unchanged) + Tier 3 rejects (the body-level logic duplication in the same finding — recorded honestly, not force-fit)
- **Status:** proposed (extractor extension only; query already implemented)

This generalizes one slice of an observed "triplicated input-assembly" finding. A reconcile-inputs bundle (a feature-flag key, a DEBUG-override precedence rule, and a liked-artists projection) was hand-copied across a SwiftUI view and an `@Observable` singleton. Only **one** slice of that triplication is detectable by clustering catalog rows — a `static let` string constant with the same value declared in two unrelated types — and even that needs the literal-catalog to start emitting string literals. The other two slices live in accessor/function bodies and are out of lane; they are recorded under "Tier 3 rejects" so a future session does not try to force a detector for them.

## Provenance — the observed sites

The finding: `ConcertSpotlightDonationService.reconcile(window:likedArtists:stationCap:dismissedConcertIDs:)` is fed the same three inputs from three places, each assembling them by hand. The review recommended hoisting the assembly to one shared factory. Grounded sites (branch `ot-c8-spotlight-donation-observer`):

**Slice A — mirrored string constant (the clustering-detectable slice):**
- `WXYC/iOS/Views/OnTour/OnTourTabView.swift:56` — `private static let stationCapFlagKey = "on_tour_for_you_station_cap"`
- `WXYC/iOS/Singletonia.swift:444` — `private static let onTourStationCapFlagKey = "on_tour_for_you_station_cap"`

Same string value, two different types in two different files, names where one contains the other (`onTourStationCapFlagKey` ⊃ `stationCapFlagKey`). The PR's own doc comment admits the copy: *"mirrored from `OnTourTabView.stationCapFlagKey` (private there)."* This is precisely the "a copy that must track another value, and copies break" smell `copied-literal-candidates.jq` was built for — a PostHog flag rename in one type silently desyncs the other.

**Slice B — mirrored override-precedence expression (Tier 3, body-level):**
- `OnTourTabView.swift:461`–`464` `concertSpotlightStationCap()` and `:387`–`390` (inside `buildForYou`)
- `Singletonia.swift:449`–`457` `currentConcertSpotlightStationCap`
- All three spell `override > 0 ? override : flagStationCap` (a `#if DEBUG` seed override taking precedence over the flag).

**Slice C — mirrored liked-artists projection (Tier 3, body-level):**
- `OnTourTabView.swift:354` `likedArtists` — `appState.likedSongsStore.songs.compactMap { song in song.artistId.map { LikedArtist(id: $0, name: song.artistName) } }`
- `Singletonia.swift:436` `currentLikedArtists` — the byte-identical projection.

The *count* is what makes Slice A cross-cutting evidence rather than a one-off; Slices B and C are the same duplication but expressed as computed-property/function bodies.

External pattern name: "extract shared constant" / "magic string" (the string sibling of the numeric case `copied-literal-candidates.jq` already handles). Detector lineage: "closed/observed refactor as detector template" (future-directions §5).

## Before-signal (the predicate)

Two `let`/`var` binding initializers whose initializer expression is a bare **string** literal, with equal literal value, in different package-qualified files (or different enclosing types), and names that contain one another case-insensitively (contained name ≥ 4 chars). Also the ≥`min_sites`/≥`min_files` cross-file cluster form for a string value repeated under the same label.

This is the *exact* predicate `copied-literal-candidates.jq` already encodes for numerics (both the copied-binding-pair lane and the cluster lane) — the query logic denies only structural numeric values (`-1/0/1/2`) and never filters on `value_kind`, so it consumes string rows unchanged the moment the extractor emits them. Passes the lit test: a predicate over literal-catalog occurrence rows (`value_norm`, `form`, `binding_name`, `enclosing_type`, `package`, `file`, `line`).

## Detector spec

**No new query.** The detector is the already-implemented `copied-literal-candidates.jq` (`pipeline/queries/copied-literal-candidates.jq`, verified present, implemented). The only work is an **extractor widening** so string literals reach `literal-catalog.json`.

- **Catalog:** `literal-catalog`
- **Shape:** cluster + pair (as the existing query already emits)
- **Logic (unchanged):** copied-binding pairs — equal `value_norm`, different `package:file` or `enclosing_type`, mutually-containing names ≥4 chars. Slice A's two constants satisfy this: `value_norm == "on_tour_for_you_station_cap"`, distinct files/types, and `ascii_downcase("ontourstationcapflagkey") | contains("stationcapflagkey")` is true.
- **Extractor change (the Tier-2 gate):** the Swift extractor's `literal` command currently emits, per contract §"Literal catalog" v1, only (1) bare **numeric** binding initializers and (2) **numeric** call arguments, and *explicitly* excludes string literals (contract.md:715). Widen v1's two emission positions to also emit string literals in those same two positions, with `value_kind: "string"` and `value_norm` = the decoded string contents **verbatim, no case-folding** (keys are case-sensitive; folding would collide `Foo`/`foo`). This is a position-set widening the contract already flags as a version bump ("Widening the position set is a version-bump" — contract.md:715), so it is schema-first and its own PR.
- **Small query follow-up (optional, same PR or next):** the numeric deny-list `IN("-1","0","1","2")` does nothing for strings; add a string deny-list so ubiquitous values don't cluster — at minimum the empty string and length-1 strings, and consider `"true"`/`"false"`. Gate this on `value_kind == "string"` so numeric behavior is untouched. This is a ~3-line query edit; the extractor widening is the real work.
- **Ready-to-paste header:** none — the existing header stands. If the desc is updated it becomes:
  ```
  #! query: copied-literal-candidates
  #! shape: cluster, pair
  #! catalog: literal-catalog
  #! desc: Repeated numeric AND string literals — cross-file value clusters and copied-binding pairs.
  ```
- **Known recall gaps (required):**
  - **Slices B and C are invisible — permanently.** The override-precedence expression and the liked-artists projection live in computed-property getters and function bodies. The declaration/literal catalogs do not read those bodies (the literal-catalog only sees *bare* literal initializers and *direct* call arguments, not literals nested in expressions — `6.0 * 2` emits nothing, and `override > 0 ? …` is an expression, not a bare initializer). Detecting duplicated *logic* is token-level clone detection, which the pipeline explicitly does not do and bans regex/grep for. So this detector catches the mirrored *constant* only, not the mirrored *rule* or the mirrored *projection* — the larger, higher-value part of the finding. State this plainly to any consumer: the flag-key cluster is a **proxy** that co-locates the two types, from which an agent can then judge the fuller triplication by reading the sites; the detector cannot see B/C directly.
  - **Even Slice A is missed if the two constants' names don't contain one another.** If a future rename made them `flagKey` and `stationCapDefaultsKey` (no containment), the pair lane goes quiet; only the ≥`min_sites` cluster lane (which needs a *third* site sharing the label) would fire. Two mirrored constants with unrelated names are below this detector's floor by design (the containment gate is the precision guard).

## Catalog needs & tier justification

- **Fields used that exist today (query side):** `value_norm`, `form`, `binding_name`, `enclosing_type`, `is_static`, `access`, `package`, `file`, `line`, `generated`. Confirmed in `docs/pipeline-contract.md` §"Literal catalog" (the JSON example at contract.md:693–715 shows `value_norm`, `form: "binding"`, and the argument-form fields; the query reads all of these).
- **Additive change required (Tier 2 — must land in `docs/pipeline-contract.md` first):** widen the literal extractor's emission set from numeric-only to numeric-plus-string in the two existing positions, and define string `value_norm` (verbatim decoded contents, no folding) and `value_kind: "string"`. This is **not a new field** — it reuses the existing `value_norm`/`value_kind`/`form` shape — but it *is* a version bump because cluster thresholds were "calibrated against this scope" (contract.md:715). Schema-first: contract PR, then extractor PR, then (optionally) the string deny-list query edit.
- **Unverified assumptions — needs check:**
  - `unverified — needs check`: that the Swift extractor's `literal` command can be extended to string literals without a value-encoding ambiguity (multiline string literals, interpolated strings). **Interpolated** string literals must be *excluded* (they are not constants — the value_norm would be misleading); emit only fully-static string literals. Confirm SwiftSyntax exposes the "is this a plain string literal with no `\(…)` segments" distinction cheaply.
  - `unverified — needs check`: whether `value_kind` is actually emitted on binding rows today (the contract's Normalization note says "`value_kind` still records the source-level type family" but the JSON example at :693 shows `value_norm` without a visible `value_kind` line). If `value_kind` is not yet emitted, the string-vs-numeric deny-list gate needs it added alongside the string widening.

## Implementation sequencing (spans tiers)

- **Ships now:** nothing new — `copied-literal-candidates.jq` already runs on numeric literals. There is no Tier-1 slice of this finding.
- **Blocked on extractor + contract (Tier 2, separate schema-first PR):** the string-literal widening. Order: (1) contract PR documenting numeric→string position widening + string `value_norm` + `value_kind` guarantee; (2) Swift extractor PR emitting static (non-interpolated) string binding + argument literals; (3) optional ≤5-line query PR adding the `value_kind == "string"` deny-list. Keep the three as separate PRs per the repo's schema-first and ≤1000-line rules; each is small.

## Restraint (when the before-state is intentional)

- **Two constants that must stay separate.** Not every same-valued string is a copy: two types can legitimately hold the same short token for unrelated reasons. The name-containment gate is the primary guard — it fires only when the names themselves assert they mean the same thing (`stationCapFlagKey` / `onTourStationCapFlagKey`). Keep it; do not loosen to bare value-equality for the pair lane.
- **String deny-list.** Empty string, single characters, and boolean-word strings (`"true"`/`"false"`) are structure, not shared knobs — the string analogue of the numeric `-1/0/1/2` deny-list. Without it, format fragments and sentinel strings would cluster noisily.
- **Generated / test / DTO code.** Standard downrank on `generated` and `is_test`. String literals mirroring a server contract (JSON keys in `Codable` `CodingKeys`, DTO field names) are intentional mirrors of an external schema, not internal copies — the cluster/pair lanes should downrank `enclosing_type` matching `(DTO|Response|Request)$` and any type conforming to `CodingKey`, consistent with the userdefaults-keytable candidate's `CodingKeys` exclusion.
- **`min_files` floor stays.** Same-file same-type siblings are locally visible and not a copy smell — the query already package-qualifies file identity and excludes same-file/same-type pairs; that discipline carries over unchanged to strings.

## Related existing queries

Grepped `pipeline/queries/` + `docs/`:

- **`copied-literal-candidates.jq`** (`pipeline/queries/copied-literal-candidates.jq`, **implemented** — verified file present) — this candidate's detector. It already implements both the copied-binding-pair lane and the cross-file cluster lane and never filters on `value_kind`, so it consumes string rows the moment the extractor emits them. This candidate is a **pure extractor extension of an existing query**, not a new query. Its own provenance (wxyc-ios-64 PR #565, `placeholderCornerRadius = 6.0` mirroring `cornerRadius = 6.0`) is the numeric twin of Slice A.
- **`2026-07-23-userdefaults-keytable-boilerplate.md`** (`docs/strategy-candidates/`, **proposed-spec**, not implemented) — adjacent and worth reading before promoting either. Its Detector B proposes a *type-catalog* field flag `fields_structured[].persisted_key` read from accessor bodies; that is a **different mechanism** for a **related** target (persistence key strings). **Synergy to flag for the promoting session:** widening the literal-catalog to string *arguments* (this candidate) would newly emit `store.set(_, forKey: "some.key")` string args as argument-form literal rows, partially overlapping that candidate's `persisted_key` need for the inline-`UserDefaults.standard` classes it calls out. A session promoting both should decide whether the literal-catalog string widening subsumes part of the userdefaults `persisted_key` extension or stays complementary (it does not fully subsume it — `persisted_key` also wants the key attached to its *property* row for per-type counting, which the literal-catalog's occurrence rows don't provide).
- **`function-duplicates.jq`** / **`near-duplicates.jq`** (both **implemented**) — the closest thing to a detector for Slices B/C, but they cluster on declaration *shape/signature*, not body tokens; near-identical bodies under different names and enclosing types are below their resolution, and chasing body-token similarity is the banned clone-detection lane. Confirming they do **not** cover B/C is the point: those slices are genuine, structural recall gaps, not a query that's merely missing.
