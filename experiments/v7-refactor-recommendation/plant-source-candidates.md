# V7 Phase A.2 — Plant Source Candidates (wxyc-ios-64)

Per [`plans/v7-refactor-recommendation-implementation-plan.md` §2.2](../../plans/v7-refactor-recommendation-implementation-plan.md) and [`docs/refactor-recommendation-experiment-plant-manifest.md`](../../docs/refactor-recommendation-experiment-plant-manifest.md). Enumerates candidate source declarations in the wxyc-ios-64 substrate from which the 25-plant V7 manifest will derive. Five categories × (4 canonical + 1 restraint) = 25 plants.

## Capture metadata

- **Substrate snapshot:** `/tmp/wxyc-ios-audit-planted/` — `type-catalog.json` (815 records, 27 are `_Plant_*` V6 artifacts to skip), `function-catalog.json` (1154 records), `file-hashes.json`, pre-built query outputs under `queries/`.
- **Capture date:** 2026-05-11 (per `ls -la /tmp/wxyc-ios-audit-planted/`). Substrate may have drifted since; spot-check before locking the manifest.
- **Selection principle (`CLAUDE.md`):** deterministic queries enumerate; judgment filters. Every candidate below traces to a `jq` invocation reproduced verbatim.
- **Exclusion:** all candidates filter out `*_Plant_*.swift` files (V6 planted artifacts, 27 declarations across 25 files). The V6 plants would otherwise inflate Cat 1/3/4 clusters.

## Caveats and ground rules

- Real Cat 2/3/4 candidates are sparse in absolute terms — the substrate is a real iOS codebase, not a textbook of refactor opportunities. Where real candidates run thin, we mark synthesized plants per the [companion manifest precedent](../../docs/refactor-recommendation-experiment-plant-manifest.md) (Plant 2.4, 3.1, 5.1 are explicitly synthesized).
- Cat 1's V6 used `AppServices:AppConfig` as Plant 1.1's source; this enumeration deliberately picks four different source types so V7 produces variety, not a re-run.
- Several real "duplications" surfaced in the substrate are *intentional* duplications (e.g., `DebugMetricsProvider` appears in both `Shared/DebugPanel` production code and `Wallpaper/Examples/WallpaperSampleApp`). Those serve as natural restraint twins — see Cat 1 restraint.
- `Shared/Analytics/Sources/AnalyticsTesting/` and `Shared/Logger/Sources/LoggerTesting/` and `Shared/Playlist/Sources/PlaylistTesting/` are "testing-flavored library targets" — *not* `Tests/` proper, but houses mock conformers and stub extensions. The methodology's `is_test`/`is_mock` context-flag (Phase B §3.6) is the right signal for these. Files under `Examples/<X>SampleApp/` get the `is_sample_app` flag.

---

## Category 1 — extract-to-common

**Template:** shape_sig appears in ≥2 packages → candidate for lifting to a shared package.

### Sampling procedure

```bash
# Cross-package exact-shape duplicates, excluding V6 plants:
jq -r '
  [.[] | select(.file | contains("_Plant_") | not) | select(.fields != null) | select(.kind == "type-alias-object" or .kind == "interface" or .kind == "extension")]
  | group_by(.shape_sig)
  | map(select(length >= 2))
  | map({shape_sig: .[0].shape_sig, field_count: (.[0].fields | length), n: length,
         packages: (map(.package) | unique), pkg_count: (map(.package) | unique | length),
         decls: map("\(.kind) \(.name) — \(.package):\(.file):\(.line)")})
  | map(select(.pkg_count >= 2))
  | sort_by(-.field_count, -.n)
' /tmp/wxyc-ios-audit-planted/type-catalog.json
```

**Counts found:** 39 cross-package exact-shape clusters (after V6-plant exclusion). Only 3 have `field_count >= 2`; the rest are single-field shapes (mostly `body: some View` / `body: some Scene` SwiftUI views, which are too thin to be meaningful refactor candidates). The four canonical picks below trade off field-count, intent-similarity, and number-of-occurrences.

### Candidates

| plant_id | name | package | file | line | shape_sig | rationale |
|---|---|---|---|---|---|---|
| 1.1 | `MetricRow` | DebugPanel | `Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift` | 53 | `body:some view\|label:string\|value:string` | Identical 3-field struct appears in DebugPanel and Wallpaper packages — textbook extract-to-shared. **Twin in WallpaperSampleApp also (see restraint).** |
| 1.2 | `PauseWXYC` | Intents | `Shared/Intents/Sources/Intents/PauseWXYC.swift` | 16 | `authenticationpolicy:intentauthenticationpolicy\|title:localizedstringresource` | Same 2-field shape as `WhatsPlayingOnWXYC` (`app:iOS`). Two intent types with identical surface — lift to a shared `AppIntent` conformance helper. |
| 1.3 | `ApplicationWillTerminateMessage` | Core | `Shared/Core/Sources/Core/Observation/ApplicationWillTerminateMessage.swift` | 15 | `name:notification.name` | 1-field shape clustering 4 declarations across Core, Playback, and MusicShareKit — clear "notification message" pattern. Lower-field-count than 1.1/1.2 but high pkg-count (3) and N (4); idiomatic Swift target is a protocol with default static `name`. |
| 1.4 | `SystemQualityClock` | Wallpaper | `Shared/Wallpaper/Sources/Wallpaper/Throttling/AdaptiveQualityController.swift` | 26 | `now:timeinterval` | The Wallpaper `Clock`/`QualityClock` pair parallels Caching's `Clock`/`SystemClock` pair exactly — 4-decl cluster across 2 packages. Lift `SystemClock` to a shared `Shared/Core` location (or remove the Wallpaper duplicate by importing). |

### Restraint twin (1R)

```bash
# Cross-package shape dup where one copy is in Examples/SampleApp (intentional duplication):
jq -r '[.[] | select(.shape_sig == "body:some view|label:string|value:string")] | .[] | "\(.package):\(.file):\(.line)"' /tmp/wxyc-ios-audit-planted/type-catalog.json
```

| plant_id | name | source pair | context flag | rationale |
|---|---|---|---|---|
| 1R | `MetricRow` (Wallpaper sample app twin) | `DebugPanel/Sources/DebugPanel/DebugHUD.swift:53` ↔ `Wallpaper/Examples/WallpaperSampleApp/Sources/DebugHUD.swift:48` | `is_sample_app=true` on the second | The two `MetricRow` structs share shape exactly, but the second is in the WallpaperSampleApp — the package's standalone demo app. Lifting it into shared production code would couple production to sample-app code; correct answer is `no-action`. **This is naturally occurring on the substrate; no synthesis needed.** Also natural at the 87% near-duplicate clustering level: `Playback:CPUSessionEvent` (272) ↔ `Analytics:MockStructuredAnalytics.CPUSessionEventProxy` (97) — a mock proxy is intentional duplication. |

---

## Category 2 — protocol inheritance (sibling-with-missing-parent)

**Template:** two protocols in the same package sharing ≥2 field names → candidate for a common parent protocol.

### Sampling procedure

```bash
# Same-package protocol pairs with >=2 overlapping field-name slots, excluding V6 plants:
jq -r '
  [.[] | select(.file | contains("_Plant_") | not) | select(.kind == "interface") | select(.fields != null and (.fields | length) >= 2)]
  | group_by(.package)
  | map(select(length >= 2))
  | .[]
  | .[0].package as $pkg
  | . as $protos
  | range(0; length) as $i | range($i+1; length) as $j
  | ($protos[$i].fields | map(split(":")[0]) | sort) as $fi
  | ($protos[$j].fields | map(split(":")[0]) | sort) as $fj
  | (($fi - ($fi - $fj)) | length) as $overlap
  | select($overlap >= 2)
  | "\($pkg)  overlap=\($overlap)\n  A=\($protos[$i].name) (\($protos[$i].file):\($protos[$i].line))\n  B=\($protos[$j].name) (\($protos[$j].file):\($protos[$j].line))"
' /tmp/wxyc-ios-audit-planted/type-catalog.json
```

**Counts found:** 8 same-package protocol pairs with ≥2 overlapping field names. The Playback package is rich (5 pairs among 5 protocols related to audio playback); Core has the cleanest match.

### Candidates

| plant_id | name (the pair) | package | files | shape | rationale |
|---|---|---|---|---|---|
| 2.1 | `MainActorNotificationMessage` + `AsyncNotificationMessage` | Core | `Observation/MainActorMessage.swift:43` + `Observation/AsyncMessage.swift:39` | 3 shared field names (`makeMessage`, `makeNotification`, `name`), differing only at the `sending` keyword on the parameter to `makeMessage` | **The single cleanest real candidate in the substrate.** Two sibling protocols, identical surface modulo a Swift 6 `sending` annotation. Missing parent is something like `protocol NotificationMessage { var name: Notification.Name; static func makeNotification(...) -> Notification }`. |
| 2.2 | `PlayerProtocol` + `HLSAVPlayerProtocol` | Playback | `PlaybackCore/Protocols/RadioPlayerProtocol.swift:16` + `HLSPlayer/Protocol/HLSAVPlayerProtocol.swift:20` | 3 shared (`pause`, `play`, `rate`) | Two player-protocol siblings; missing parent is `PlaybackTransport` (or similar). HLS adds `seek` + `currentTime` + `seekableTimeRanges`; the parent captures the common transport surface. |
| 2.3 | `AudioEnginePlayerProtocol` + `AudioPlayerProtocol` | Playback | `MP3Streamer/Playback/AudioEnginePlayerProtocol.swift:34` + `PlaybackCore/Protocols/AudioPlayerProtocol.swift:19` | 6 shared (`eventStream`, `installRenderTap`, `isPlaying`, `play`, `removeRenderTap`, `stop`) | Strongest overlap (6/9 fields). Missing parent captures the render-tap + lifecycle surface; `AudioEnginePlayerProtocol` adds buffer-scheduling on top. |
| 2.4 | `AudioPlayerProtocol` + `PlaybackController` | Playback | `PlaybackCore/Protocols/AudioPlayerProtocol.swift:19` + `PlaybackCore/Protocols/PlaybackController.swift:27` | 7 shared (`installRenderTap`, `isPlaying`, `makeAudioBufferStream`, `play`, `removeRenderTap`, `state`, `stop`) | Highest overlap (7/9-10). Missing parent is a `RenderingAudioPlayer` core; `PlaybackController` adds higher-level `isLoading`, `toggle` controls. The pair suggests a shared protocol the substrate didn't lift; this is the closest the substrate comes to plant 2.1's canonical "missing-parent" shape. |

### Restraint twin (2R)

| plant_id | source pair | context flag | rationale |
|---|---|---|---|
| 2R | **Synthesized: parallels Cat 2.1.** A `MockNotificationMessage` test-only protocol in `Shared/Core/Sources/CoreTesting/MockNotificationMessage.swift` (path *to be planted*) overlapping with `AsyncNotificationMessage` on `name` + `makeNotification`. | `is_test=true` (path under a `*Testing/` library target — same convention as `Shared/Playlist/Sources/PlaylistTesting/`) | No real Cat 2 protocol pair exists where one is in a Tests target — `Shared/*Testing/` has mock *classes*, not mock protocols. Synthesize the restraint as a test-side mock protocol; the correct answer is `no-action` because lifting the mock's surface into the production parent would couple production to the test mock. |

---

## Category 3 — default implementation

**Template:** ≥3 functions with identical normalized body across types in the same package → missing default-impl on a shared protocol.

### Sampling procedure

```bash
# Body-hash clusters across same-or-different types, excluding V6 plants:
jq -r '
  [.[] | select(.file | contains("_Plant_") | not)]
  | group_by(.body_hash)
  | map(select(length >= 2))
  | map({n: length, body_line_count: .[0].body_line_count, pkg_count: (map(.package) | unique | length),
         funcs: map("\(.kind) \(.name) — \(.package):\(.file):\(.line)"),
         body: (.[0].body_lines | join(" | "))})
  | sort_by(-.n, -.body_line_count) | .[]
' /tmp/wxyc-ios-audit-planted/function-catalog.json
```

Auxiliary check on near-duplicate function bodies in the same package (Jaccard ≥ 0.7) sourced from `/tmp/wxyc-ios-audit-planted/queries/function-duplicates.txt`.

**Counts found:** 32 exact body-hash clusters, 22 near-duplicate pairs at ≥70% Jaccard. **Only one body-hash cluster has `n >= 3`** (the HSBColor / AccentColor / HSBOffset init); the rest are pairs. Cat 3's canonical shape requires ≥3 conformers — the substrate is short on real ≥3 clusters, so plants 3.2–3.4 synthesize, modeled on the strongest real ≥2 pairs.

### Candidates

| plant_id | source | package | files / lines | body_hash kind | rationale |
|---|---|---|---|---|---|
| 3.1 | `init(hue:saturation:brightness:)` shared across `HSBColor`, `AccentColor`, `HSBOffset` | ColorPalette + Wallpaper | `ColorPalette/HSBColor.swift:31`, `Wallpaper/Core/ThemeColors.swift:62`, `Wallpaper/Core/ThemeColors.swift:198` | 3-line identical body: `self.hue = hue; self.saturation = saturation; self.brightness = brightness` | **The single real n=3 body-hash cluster in the substrate.** Three types in two related packages share an identical init body — natural default-impl candidate (with the caveat that initializers can't be default-impl'd directly; the refactor is "common HSB-color stored-properties struct, embed via composition"). Useful for the rubric's `alternative_answers` (extract-to-common at weight 0.4). |
| 3.2 | `PlaybackBlendMode.displayName` / `MaterialBlendMode.displayName` (+ symmetric `.blendMode`) | Wallpaper | `Wallpaper/Core/PlaybackBlendMode.swift:41` + `Wallpaper/Core/MaterialBlendMode.swift:41` | 18-line identical switch over 16 cases (and a parallel 18-line `.blendMode` getter at line 62 in each file) | Real n=2 pair where *two distinct methods* on the pair have identical bodies — and the underlying types are 16-case unions sharing the same case names. **Synthesized third conformer** added in Wallpaper (`_Plant_*.swift`) makes the n=3 default-impl signal. Note: this candidate doubles as a Cat 5 generic-parameterization candidate; Cat 3 uses the function-body angle, Cat 5 the struct-shape angle — see Cross-checks. |
| 3.3 | `RMSProcessor.setNormalizationMode` / `FFTProcessor.setNormalizationMode` (+ symmetric `.reset`) | PlayerHeaderView | `Sources/PlayerHeaderView/RMSProcessor.swift:61, 55` + `Sources/PlayerHeaderView/FFTProcessor.swift:189, 183` | 3-line identical body using `normalizerMutex.withLock` | Two real conformers of the `AudioProcessor` protocol (`fields=["process","reset","setNormalizationMode"]`). **The protocol already exists** — but the default impls don't. Synthesize a third conformer (`_Plant_AverageProcessor.swift`) and propose the obvious refactor: `extension AudioProcessor { default reset() / setNormalizationMode() }`. |
| 3.4 | `Breakpoint.init(from:)` / `Talkset.init(from:)` (and the symmetric `.init(id:hour:chronOrderID:timeCreated:)`) | Playlist | `Playlist/PlaylistEntry.swift:64, 57` + `Playlist/PlaylistEntry.swift:103, 96` | 5-line identical `Decodable` initializer body | Two real `PlaylistEntry` conformers with identical decoder bodies. **The `PlaylistEntry` protocol exists.** Synthesize a third conformer (`_Plant_Announcement.swift`) and propose: protocol gets a default `init(from:)` via `extension PlaylistEntry where Self: Decodable { ... }`. |

### Restraint twin (3R)

```bash
# Same body hash across 3 functions where >=1 is in a test/mock:
# Manually verified using PlaylistStubs.swift (PlaylistTesting target).
```

| plant_id | source | context flag | rationale |
|---|---|---|---|
| 3R | `Breakpoint.stub` / `Talkset.stub` (in `Shared/Playlist/Sources/PlaylistTesting/PlaylistStubs.swift:58, 75`) | `is_mock=true` (file under `*Testing/` library target, names start with `stub`) | Two 6-line identical bodies that are *intentionally identical test fixtures*. Lifting them into a protocol default would coerce production-protocol shape to a test convenience. Correct answer: `no-action`. Surfaces in `function-duplicates near` cluster at 71% (∩=5/∪=7) — same query signal as Cat 3 canonical, distinguished only by the test-target context flag. To reach the `n >= 3` constraint, synthesize a planted `_Plant_PlaycutStub.swift` in the same `PlaylistTesting/` directory mirroring the same body. |

---

## Category 4 — PAT introduction

**Template:** protocol or struct pairs whose field-name sets match exactly but where ≥1 type-slot differs.

### Sampling procedure

```bash
# Type pairs with identical sorted field-name sets, where the (sorted) full fields strings differ (i.e., type slots differ):
jq -r '
  [.[] | select(.file | contains("_Plant_") | not) | select(.fields != null) | select(.kind == "interface" or .kind == "type-alias-object")]
  | [.[] | . as $t | $t + {field_names: ($t.fields | map(split(":")[0]) | sort | join("|")), field_count: ($t.fields | length)}]
  | group_by(.field_names)
  | map(select(length >= 2)) | map(select(.[0].field_count >= 2))
  | map({field_names: .[0].field_names, field_count: .[0].field_count, n: length,
         diff_count: (((.[0].fields | sort) - (.[1].fields | sort)) | length),
         members: map({name, kind, package, file, line, fields})})
  | map(select(.diff_count >= 1)) | sort_by(-.field_count, .diff_count) | .[]
' /tmp/wxyc-ios-audit-planted/type-catalog.json
```

**Counts found:** 3 real type pairs with identical field-name sets but ≥1 type-slot difference:
1. `DebugMetricsProvider` (DebugPanel vs WallpaperSampleApp) — 12 fields, 1 diff (`MTLDevice?` vs `(any MTLDevice)?` — a Swift-6 syntax variant, not semantically different).
2. `MainActorNotificationMessage` vs `AsyncNotificationMessage` — already used in Cat 2; PAT and missing-parent overlap here (see Cross-checks).
3. `NowPlayingItem` (AppServices) vs `PlaycutSelection` (app:iOS) — 2 fields, `Image?` vs `UIImage?` at the artwork slot.

**Real Cat 4 candidates are sparse.** This matches the methodology's expectation (§5.4 — "no V6 surface"). Three of the four canonical candidates below are synthesized, modeled on real parallel-name patterns in the substrate.

### Candidates

| plant_id | source / synthesis | package | rationale |
|---|---|---|---|
| 4.1 | **Real:** `NowPlayingItem` (AppServices, `NowPlayingService.swift:23`) ↔ `PlaycutSelection` (app:iOS, `PlaylistView.swift:23`). Both have `{artwork: <Image>?, playcut: Playcut}`; differ at `Image` vs `UIImage`. | AppServices + app:iOS | Real cross-package PAT shape. Differ at one type slot exactly. Right answer: introduce `protocol PlaycutWithArtwork { associatedtype Artwork; var playcut: Playcut; var artwork: Artwork? }`. Some weakness: `Image` and `UIImage` are platform-flavor variants rather than orthogonal domain types — agent might prefer a typealias. |
| 4.2 | **Synthesized:** `TrackContainer<Track>` + `ShowContainer<Show>` planted into `Shared/Playback/Sources/PlaybackCore/_Plant_*.swift`. Models the methodology §5.4 canonical exactly. | Playback (synthesized) | Companion manifest plant 4.1's template; canonical PAT shape (`var item: Track / Show`, `func reload() async`). Real-substrate echo: the `MusicService` protocol family in MusicShareKit has 5 conformers (`AppleMusicService`, `BandcampService`, `SoundCloudService`, `SpotifyService`, `YouTubeMusicService`) — synthesized plant parallels that pattern's intent. |
| 4.3 | **Synthesized:** `ArtistRepository` + `ReleaseRepository` planted in `Shared/Metadata/Sources/Metadata/_Plant_*.swift`. Three-way at higher arity if needed. | Metadata (synthesized) | Maps to the existing `DiscogsEntityResolver` protocol (`resolveArtist`, `resolveMaster`, `resolveRelease`) — three parallel members suggest a missing PAT-shape `protocol EntityResolver { associatedtype Entity; func resolve(...) async throws -> Entity }`. The substrate has parallel methods, not parallel protocols — synthesizing the parallel-protocol shape mirrors real intent. |
| 4.4 | **Synthesized with effect specifiers:** `CacheLoader<Data>` + `MetadataLoader<Metadata>` differing at both return type *and* `async throws` effect specifiers. Plant locations: `Shared/Caching/Sources/Caching/_Plant_CacheLoader.swift` + `Shared/Metadata/Sources/Metadata/_Plant_MetadataLoader.swift`. | Caching + Metadata (synthesized) | Targets plant 4.4 (effect specifiers) in companion methodology §5.4. The `Cache` and `PlaycutMetadataService` protocols both have load-shaped methods today but differ structurally; the synthesis isolates the effect-specifier dimension. |

### Restraint twin (4R)

| plant_id | source | context flag | rationale |
|---|---|---|---|
| 4R | **Real:** `Playback:CPUSessionEvent` (line 272 of `PlaybackAnalytics.swift`) ↔ `Analytics:MockStructuredAnalytics.CPUSessionEventProxy` (line 97). 87% near-duplicate (`∩=7 ∪=8`). | `is_mock=true` (file is in `AnalyticsTesting/` library target with `Mock` name prefix). | Same field-name set modulo one slot (`properties` field on the real one) — looks like a PAT candidate to a context-blind reader, but the proxy exists *to record the real event's fields* in tests. Lifting both behind a PAT couples production to test-mock semantics. Correct answer: `no-action`. **Naturally occurring; no synthesis needed.** |

---

## Category 5 — generic parameterization

**Template:** function pairs with same body modulo type-identifier substitution, OR struct pairs differing only at one type slot. Per §2.2 of the plan, target ~3 function-shaped and ~2 struct-shaped plants across the 5 plants.

### Sampling procedure

```bash
# Function near-duplicates (Jaccard >=0.7 on body_lines) — pre-built:
cat /tmp/wxyc-ios-audit-planted/queries/function-duplicates.txt
# (already used in Cat 3; the near-duplicate section is the type-erased-body proxy)

# Struct pairs differing at one type slot — same query as Cat 4 above; rows with diff_count==1
# but kind type-alias-object (struct, not interface).
```

**Counts found:** see Cat 3 & 4 query outputs. Real n=2 function pairs with type-identifier-differing bodies: `HSBColor.uiColor` ↔ `HSBColor.nsColor` (∩=5 ∪=7); `MainActorNotificationMessageSequence.AsyncIterator.init` ↔ `AsyncNotificationMessageSequence.AsyncIterator.init` (∩=12 ∪=14, both 13 lines). Real struct pairs: `PlaybackBlendMode` vs `MaterialBlendMode` (16-case union with case names identical); `MainActorNotificationMessageSequence` vs `AsyncNotificationMessageSequence` (3 fields, generic `M:` constraint differs).

### Candidates (≈3 function + ≈2 struct)

| plant_id | shape | source | package / location | rationale |
|---|---|---|---|---|
| 5.1 (fn) | Function pair, type-id substitution | `HSBColor.uiColor` ↔ `HSBColor.nsColor` (`ColorPalette/HSBColor.swift:53, 63`) | ColorPalette | Real intra-type same-package pair. Bodies differ only at `UIColor` ↔ `NSColor` (∩=5 ∪=7, 71% Jaccard). Right answer: generic free function (or extension method) keyed on a `PlatformColor` typealias / protocol. |
| 5.2 (fn) | Function pair, type-id substitution | `MainActorNotificationMessageSequence.AsyncIterator.init(center:subject:onSubscribed:)` ↔ `AsyncNotificationMessageSequence.AsyncIterator.init(center:subject:onSubscribed:)` (`Core/Observation/MainActorMessage.swift:152` + `AsyncMessage.swift:126`) | Core | 85% Jaccard, ∩=12 ∪=14. Identical iterator initialization body modulo `@MainActor` decoration. The full file pair (MainActor vs Async) is one of the strongest deduplication candidates in the substrate; this plant zeroes in on the per-function angle. |
| 5.3 (fn) | Function pair, type-id substitution | **Synthesized:** Plant a `Shared/Caching/Sources/Caching/_Plant_GenericFetcher.swift` containing two functions `fetchInt` and `fetchString` with identical bodies differing only at the parameterized type. | Caching (synthesized) | Companion methodology §5 canonical (parallels plant 5.1 in the companion manifest — `IntCache` + `StringCache`). Synthesizes the function-shaped version. |
| 5.4 (struct) | Struct pair, type-slot differs | `MainActorNotificationMessageSequence` (`MainActorMessage.swift:129`) ↔ `AsyncNotificationMessageSequence` (`AsyncMessage.swift:103`). Both 3 fields, both generic on `M:`, differ at the protocol bound. | Core | The struct-shaped angle on the same MainActor/Async parallel that drove 5.2 and 2.1. Identical field-name sets, identical-modulo-one-protocol-bound types. Right answer: a generic `NotificationMessageSequence<M: NotificationMessageBase>` where `NotificationMessageBase` is the missing-parent protocol from Plant 2.1 (cross-references intentionally; see Cross-checks). |
| 5.5 (struct) | Struct pair, type-slot differs | **Synthesized:** Plant `IntCache` + `StringCache` into `Shared/Caching/Sources/Caching/_Plant_IntCache.swift` and `_Plant_StringCache.swift`, exactly per companion plant 5.1. | Caching (synthesized) | The companion manifest's canonical struct plant. Synthesized because the real substrate's `Cache` protocol already abstracts over data — no parallel non-generic concrete caches exist to lift. |

### Restraint twin (5R)

| plant_id | source | context flag | rationale |
|---|---|---|---|
| 5R | **Real:** `Breakpoint.stub` ↔ `Talkset.stub` (already used in 3R) — bodies parallel each other modulo the type the stub returns. The pair is in `PlaylistTesting/PlaylistStubs.swift` (mock context). | `is_mock=true` | Two struct stubs whose bodies parallel each other at the construction-site type — looks like a generic-function refactor candidate to a context-blind reader. But generifying test stubs into a single `<T>` helper either coerces all stubs to a common surface or requires per-type customization that defeats the purpose. Correct answer: `no-action`. Reuses 3R's source pair under a different category lens; this is by design (one cluster, two-category restraint coverage). |

---

## Cross-checks

Validating no canonical plant accidentally tests two categories:

| candidate | category | cross-category risk | resolution |
|---|---|---|---|
| 1.1 `MetricRow` | Cat 1 | Could surface as 4 (same field names, types differ)? | **No.** The two `MetricRow` declarations have *identical* field types (`label:String`, `value:String`, `body:some View`). Pure exact-duplicate (Cat 1), not a PAT candidate. |
| 1.2 `PauseWXYC` | Cat 1 | Cat 4 risk: identical field-name set? | **No.** `PauseWXYC` and `WhatsPlayingOnWXYC` have identical types at both slots (`IntentAuthenticationPolicy`, `LocalizedStringResource`). Pure Cat 1. |
| 1.3 `ApplicationWillTerminateMessage` | Cat 1 | Cat 3 risk: do the conformers share method bodies? | These are 1-field structs; no method bodies to compare. Pure Cat 1. |
| 1.4 `SystemQualityClock` | Cat 1 | Cat 2 risk (protocol + impl): `QualityClock`/`Clock` are protocols, `SystemQualityClock`/`SystemClock` are structs conforming to them. | Cat 1 angle is "the *struct* shape repeats across packages." Cat 2 would require a protocol-protocol overlap; here we have protocol-struct conformance. Distinct. |
| 2.1 `MainActorNotificationMessage + AsyncNotificationMessage` | Cat 2 | **Real Cat 4 overlap** — same field-name set, differs at one type slot (`sending` keyword). Also drives Cat 5.2 and 5.4. | **Intentionally a multi-signal substrate cluster** — the substrate is rich here and the same source pair drives plants 2.1, 5.2, and 5.4 (and overlaps weakly with 4.1's pattern). The plants take *different angles* on the same cluster (missing-parent vs generic-iterator vs generic-sequence). The agent's job per-plant is to recommend the *categorically correct* refactor for the given cluster row; one PR could consolidate all three, but per-plant the recommendation answers a different question. Flagged here for transparency. |
| 2.2–2.4 (Playback protocol family) | Cat 2 | Could surface as Cat 4 if field names match. | They don't — Playback protocol pair fields overlap on names but differ on additional fields; this is the "missing parent" shape (Cat 2), not the "differs only at one type slot" shape (Cat 4). Distinct. |
| 3.1 HSBColor init | Cat 3 | Cat 5 (function/generic) risk. | The HSB init bodies are *byte-identical* — there's no type-identifier substitution to generify over. Pure Cat 3 signal (default-impl candidate); the Cat 5 lens needs differing types. Distinct. |
| 3.2 BlendMode pair | Cat 3 | **Cat 5 overlap noted in candidate row.** | The function-body duplication is the Cat 3 angle (default-impl on a shared `BlendMode` protocol); the 16-case union duplication is the Cat 5 angle (generic union over `BlendModeCase`). Plants chosen to use the function-body angle for 3.2 and synthesize the struct-angle elsewhere. |
| 3.3 PlayerHeaderView pair | Cat 3 | Cat 2 risk: AudioProcessor protocol already exists. | Exactly so — Cat 3 plant adds the *default-impl* angle on the existing protocol, not a new parent. Distinct from Cat 2. |
| 3.4 PlaylistEntry pair | Cat 3 | Same as 3.3. PlaylistEntry protocol exists. | Plant 3.4 adds default impl, distinct from Cat 2 (no missing parent). |
| 4.1 NowPlayingItem / PlaycutSelection | Cat 4 | Cat 1 risk (shape near-dup). | Field names match exactly; types differ — that's the PAT signature, not extract-to-common. Distinct. |
| 4.2/4.3/4.4 synthesized | Cat 4 | n/a — fresh synthesized plants. | OK. |
| 5.1 HSBColor color methods | Cat 5 | Cat 3 risk: same type, two methods. | The two methods are on the *same* type, so it's not a Cat 3 "default-impl across types" candidate — it's a generic-function candidate. Distinct. |
| 5.2 NotificationSequence Iterator init | Cat 5 | Cat 3 risk (default impl across types) and Cat 2 risk. | The bodies have type-identifier substitution (`@MainActor` annotation differs) — Cat 5 angle. The protocol-level pair is 2.1; the iterator-init level pair is 5.2; they share the substrate cluster but answer different questions. Acknowledged overlap. |
| 5.4 NotificationSequence struct | Cat 5 | Same as 5.2. | Acknowledged; see 2.1 cross-check above. |

### Multi-signal clusters acknowledged

The MainActor/Async notification cluster in Core drives **plants 2.1, 5.2, and 5.4**. This is consistent with how the methodology treats the V7 plant set: plants are *recommendations the agent emits for one cluster row*, and one cluster row can legitimately admit multiple categorical recommendations. Per the [methodology §10 pre-registration review criterion #2](../../docs/refactor-recommendation-experiment-methodology.md#pre-registration), the review must explicitly check "does any plant accidentally test two categories at once?" — the answer here is "the substrate cluster drives three plants, each targeting a distinct lens; the rubric's per-plant `primary_answer` schema isolates which categorical recommendation each plant scores against." This is the correct shape; the alternative (three plants pointing at three distinct clusters) would waste real-substrate signal.

The other multi-lens cluster is **3.2 BlendMode** which the rubric scores at the function-body angle; the struct-body angle is left to Cat 5 synthesized plant 5.5 to avoid double-counting.

## Summary

- **Cat 1 (extract-to-common):** 4 real canonical + 1 real restraint (`MetricRow` sample-app twin). All real.
- **Cat 2 (protocol inheritance):** 4 real canonical (Core notification pair + 3 Playback player-protocol overlap pairs). **1 synthesized restraint** (no real test-target protocol pair exists in the substrate).
- **Cat 3 (default implementation):** **1 real n=3 canonical** (HSBColor / AccentColor / HSBOffset init) + **3 hybrid canonical** (real n=2 pair + synthesized 3rd conformer to hit the methodology's "≥3 conformers" requirement). Restraint reuses 3R cluster (`stub` pair in PlaylistTesting). The substrate's scarcity of n≥3 clusters is the headline surprise.
- **Cat 4 (PAT introduction):** **1 real canonical** (`NowPlayingItem` / `PlaycutSelection`) + **3 synthesized** modeled on existing parallel-name patterns. Real restraint twin (`CPUSessionEvent` / `MockStructuredAnalytics.CPUSessionEventProxy`).
- **Cat 5 (generic parameterization):** **2 real fn candidates** (HSBColor color methods, NotificationSequence iterators), **1 synthesized fn**, **1 real struct candidate** (NotificationSequence), **1 synthesized struct**. Restraint reuses `stub` pair under the generic-function lens.

### Synthesis tally

| category | real canonical | synthesized canonical | restraint kind |
|---|---|---|---|
| 1 | 4 | 0 | real |
| 2 | 4 | 0 | synthesized |
| 3 | 1 + 3 (real-pair-plus-third-conformer) | 0 pure-synth | real (reuses) |
| 4 | 1 | 3 | real |
| 5 | 3 | 2 | real (reuses) |

### Reproducibility

All jq invocations above are reproduced verbatim and run against `/tmp/wxyc-ios-audit-planted/{type-catalog.json,function-catalog.json}` captured 2026-05-11. Re-running them on a fresher catalog may surface drift; if so, re-validate before locking the manifest per [plan §2.2 acceptance criteria](../../plans/v7-refactor-recommendation-implementation-plan.md).
