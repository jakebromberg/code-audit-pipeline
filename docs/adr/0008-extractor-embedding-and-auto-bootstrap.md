# Embed extractor source; auto-extract and bootstrap on first use

`code-audit` embeds the contents of `extractors/<lang>/` into the binary via `//go:embed` (alongside `pipeline/queries/*.jq` from [ADR-0006](0006-bundling-and-discovery.md)). When the discovery chain (ADR-0006, tiers 1–4) resolves to tier 4 (`~/.config/audit/extractors/`) and the requested extractor is missing, `code-audit extract <name>` auto-extracts the embedded source into tier 4 and runs the manifest's `[runtime].bootstrap` argv (e.g. `["npm", "install"]`) automatically. Per-extractor `flock(2)` plus state.json tracking serialise concurrent callers and survive failures.

The split this ADR establishes: **extractor *source* is embedded; extractor *runtime* is not.** A user with `brew install jakebromberg/tap/code-audit` and `node` on `$PATH` can `code-audit extract typescript --root ~/repo` with no other install steps. A user without `node` sees the same auto-extract succeed for source layout but the `npm install` bootstrap fails — surfaced one-line in `code-audit status` with the manifest's `setup_hint`.

## Source-vs-runtime distinction

Extractor *source* (≤ 100KB per extractor — `.mjs`, `.swift`, `.py`, manifest, fixtures) embeds cleanly into the binary at zero meaningful artifact cost. Extractor *runtime* (Node modules, Swift toolchain, future pip dependencies) cannot reasonably embed: the TypeScript extractor's `node_modules/` is ~80MB. The binary embeds the cheap half and delegates the expensive half to a manifest-declared `[runtime].bootstrap` argv the binary runs on first use.

## Auto-extract trigger gate

The auto-extract path fires **iff** the discovery chain resolves to `TierConfigDir` (tier 4: `~/.config/audit/extractors`). Any earlier tier resolving — `TierFlag` (`--extractors-dir`), `TierCwd` (cwd-relative), or `TierAuditHome` (`$AUDIT_HOME`) — preempts auto-extract entirely. The user/contributor is signalling "I'm managing source here" and the binary doesn't second-guess that.

Consequence: a contributor running `code-audit extract typescript` inside a `code-audit-pipeline` checkout (tier 2 via cwd-relative `./extractors/`) gets their live source, not the embedded snapshot. The binary never mutates a non-tier-4 path.

## State.json schema additions

`<dest>/.audit-init/state.json` grows an `extractors` map alongside the existing per-file `files` map:

```json
{
  "files": { ... existing ... },
  "extractors": {
    "typescript": {
      "bootstrap_status": "ok",
      "bootstrapped_at": "2026-06-01T12:34:56Z",
      "source_sha": "<combined SHA of laid-down source>",
      "last_error": ""
    }
  }
}
```

`bootstrap_status` is one of `ok | failed | pending | n-a`. Transitions: `pending → ok | failed | n-a`. `n-a` is terminal for an extractor whose manifest declares no `[runtime].bootstrap`.

## Manifest schema bump (1 → 2)

Schema 2 adds an optional `[runtime].bootstrap` array. The validator rejects `[runtime].bootstrap` on a schema-1 manifest with a clear error mentioning the schema-version requirement (`schema_version >= 2`), preventing the field from going un-recognised in older readers. Schema 2 readers ignore the field when absent and treat the extractor as `bootstrap: n-a` once it is laid down.

## Concurrency: per-extractor flock + state.json coordination

Two layers:
1. **flock** at `<extractorsRoot>/<name>/.audit-init/lock` serialises *writers*. 60s blocking timeout via a polling loop that respects `ctx.Done()`. POSIX advisory lock; the kernel releases on process exit even if the binary crashes.
2. **state.json** carries *outcome* across processes. A failed bootstrap is recorded as `failed` + `last_error` **before the lock is released**, so the next caller observes the failure and decides whether to retry.

The check inside the lock is content-based, not stat-based: state.json's `source_sha` must match the embedded source's combined SHA AND every state-tracked file under the extractor dir must hash to its recorded pristine SHA. Stat-based shortcuts (file exists / mtime newer) miss the case where source moved between binary versions.

## Executable-bit heuristic

`//go:embed` strips file mode bits — every embedded file appears as `0o444`. The binary cannot preserve the source's exec bit declaratively, so it sniffs the first two bytes of each embedded file at lay-down time:

- `#!` shebang → `0o755`
- anything else → `0o644`

Cost: open + read 2 bytes per file (negligible for the ~10 files in the TS extractor; bounded by file count for larger extractors). The heuristic has one accepted false positive — a binary file whose first two bytes happen to be `0x23 0x21` is treated as a script. The TS extractor (and all currently-planned extractors) have no such files; future extractors that need finer control can declare an `[runtime].executable_patterns` regex in a follow-up schema bump.

For filesystem sources (`init --from <checkout>`), source mode bits flow through `fs.Stat` unchanged — the heuristic applies only to embedded sources.

## `node_modules` under `~/.config/audit/`

The bootstrap pass writes runtime state (e.g. `extractors/typescript/node_modules/`) into the same dest dir as source. The alternative — splitting source under `~/.config/` and runtime state under `~/.cache/` — requires `NODE_PATH` gymnastics, breaks atomic upgrade semantics (re-laying source would orphan the cache), and adds a second place that can desync from state.json. We accept the simpler layout: one extractor dir, one lock, one state record.

## Symlink-traversal semantics

`buildCopyPlan` walks via `fs.WalkDir`, which does not recurse into symlinked directories on either backend. Symlink files are dropped outright. This is a behaviour change from the prior `filepath.WalkDir`-based code, which did descend into symlinked directories under `--from`. Migration consequence: users with symlink-based extractor source trees should check files in directly, or materialise the symlinks before `init --from`.

Rationale: the symmetry between `--from` and embedded source paths is worth the divergence; it also closes an attack surface where a hostile symlink under `--from <untrusted>` could trigger arbitrary recursion.

## Downgrade migration

state.json is **forward-compatible only**. An old binary reading a new state.json silently drops the `extractors` field on write (Go's `json.Marshal` simply omits the missing struct field). The user who downgrades after running the new binary loses extractor bootstrap state. The next run of the new binary observes `Extractors == nil` and re-bootstraps once — auto-recovery, no manual intervention required.

No corruption, no panic; pre-1.0 acceptable. `code-audit status` surfaces the slow path: extractors whose state was migrated from an old format show `bootstrap: pending (will run on next extract)`, so the user sees the one-time delay coming rather than discovering it via a surprise 30-second pause.

## Considered Options

- **Network fetch at first use.** Adds a runtime dependency on GitHub Releases or a CDN, forks the install story across air-gapped environments, complicates the brew formula. Embedding source is ~100KB per extractor and amortises over the binary download.
- **Lazy bootstrap on first invocation, no auto-extract.** Forces users to run `code-audit init` before any extract — the original pre-#234 state. Loses the one-step brew UX that motivates this whole change.
- **Embed runtime too.** Possible for Node via embedded V8 + node_modules tarball but breaks down for Swift (toolchain-dependent binaries) and Python (pip+venv complexity). Not worth the per-language inconsistency.
- **Embed source, auto-extract on first use, manifest-declared bootstrap** (chosen).

## Scope boundary

This ADR does **not** amend the discovery chain from [ADR-0006](0006-bundling-and-discovery.md). The chain (tiers 1–4) is unchanged. ADR-0008 specifies only what happens when the chain resolves to tier 4 and tier 4 is empty / stale (auto-extract + bootstrap), and how the auto-extract phase walks the source tree (no symlink following). Future ADRs that change the chain itself supersede ADR-0006, not 0008.
