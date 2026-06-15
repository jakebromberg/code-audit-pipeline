# Plan — #281: PR-comment synthesis layer (LLM interpretation of extracted clusters)

Parent ticket: [#281 — feat: PR-comment synthesis layer (opt-in LLM interpretation) + metric-touched-filter fix](https://github.com/jakebromberg/code-audit-pipeline/issues/281).

## Goal

Add an opt-in synthesis step to the PR-comment reusable workflow that turns the renderer's raw cluster output into a short, reviewer-actionable comment ("your PR touched X, which is one of N sites of pattern P — propagate, leave alone, or consolidate?"), while preserving the existing deterministic raw rendering as workflow-artifact debug evidence.

## Why this scope shape

The project's stated principle is *deterministic extraction, agentic synthesis* (CLAUDE.md). Today's PR-comment surface ships only the first half: extractors emit a catalog, jq queries cluster rows, the Go renderer formats those rows as markdown, the result gets posted verbatim. There is no synthesis layer — reviewers see structured intermediate output and are silently expected to interpret it.

The triggering observation: `WXYC/Backend-Service#1423` is a YAML-only PR (workflow + .gitignore). The audit comment posted 19 sections of `shape-sig-frequency` global TypeScript histograms with no per-file payload and no relationship to the PR's diff. Two compounding problems:

1. A real bug in `internal/cli/report_pr_comment.go:171-178` blanket-passes every `shape: metric` row through the `--touched` filter, on the false premise that all metric queries self-filter internally. Only `touched-window-debt-summary.jq` actually does. The other four metric queries (`shape-sig-frequency`, `migration-progress`, `coverage`, `preflight-versions`) are global and leak through.
2. Even after that bug is fixed, the *output shape* is still "rendered structured data." When cluster rows survive the touched-filter, the renderer produces `<package>:<file>:<line>` lists with `*` markers for touched members — adequate but unsynthesized. The reviewer still has to look at the cluster, count the sites, infer what the pattern means, and decide if the PR's change belongs.

The user-facing fix is not just "drop the metric noise." It is "ship the project's tagline." Synthesis is the missing layer.

The shape that minimizes blast radius:

- **Keep the Go binary fully deterministic.** No LLM call, no API-key dependency, no network egress from `code-audit report` or any other binary subcommand. The binary's contract — single executable, byte-reproducible output, no secrets — stays intact.
- **Add the synthesis step to the reusable GitHub Actions workflow only.** A new composite action runs after the renderer, takes the rendered raw markdown + the catalog rows that survived the touched-filter + the PR diff metadata, and produces a synthesized comment via an LLM API call.
- **Default opt-out.** Every existing consumer of `pr-comment-reusable.yml@v*` keeps current behavior on the next release bump. Opting in is one workflow-input flip plus a secret.

Filed as its own issue (not folded into the metric-bypass bug or into the wider `audit-pr-comment` composite refactor #273) so the design discussion can settle before code lands, and so consumers can review the new capability separately from the bug fix.

## Discrepancy worth resolving up front

The project's principle (CLAUDE.md, "The principle (do not violate)") names two boundaries the LLM must respect:

> The pipeline draws a sharp line: deterministic tools do cataloging, LLMs do small, focused judgment. If you find yourself proposing N parallel agents to enumerate types, functions, routes, migrations, or anything else structural — stop. Write the AST extractor.

This proposal threads that needle: the LLM never enumerates. The catalog is built deterministically, the queries cluster deterministically, the touched-filter scopes deterministically. The LLM only sees rows that survived all those filters, and its job is bounded to *prose generation about those rows* — not "find me bugs," not "propose patches," not "guess intent from the diff."

Lit-test from CLAUDE.md ("can the question be answered by clustering structured rows?"): the answer here is *partly*. The clustering answers "what patterns exist and which sites are touched." It does not answer "is the touched site's relationship to the pattern intentional, or should the reviewer notice it?" That second question is judgment, and judgment is what the synthesizer is for.

If during review someone argues "the synthesizer is creeping into enumeration," that's a real concern — answer it by re-checking that every fact in the prompt came from the catalog and that the LLM is only asked to write prose, not extract.

## Design

### Pipeline shape

Current `pr-comment-reusable.yml` flow (after #274 inlined the steps):

```
checkout → derive paths → audit-core (catalog) → resolve touched files → render PR comment → post sticky → upload artifact → emit summary
```

Proposed flow with synthesis enabled:

```
checkout → derive paths → audit-core (catalog) → resolve touched files → render PR comment →
  [if enable-synthesis] synthesize prose → post synthesized comment + raw artifact
  [else]                                  → post raw comment + raw artifact (today's behavior)
```

The synthesis step is a new composite action `audit-pr-synth` invoked as a workflow step between `render` and `post`. The post step posts whichever markdown the synth step emits (synthesized when enabled, raw passthrough when disabled). The artifact upload always carries the raw rendering for debugging, regardless of which path was taken.

### Workflow inputs

Two new inputs on `pr-comment-reusable.yml`:

| Input | Type | Default | Purpose |
|---|---|---|---|
| `enable-synthesis` | boolean | `false` | Master switch. Off → today's behavior, no LLM call, no secret required. |
| `synthesis-secret-name` | string | `ANTHROPIC_API_KEY` | The name of the consumer-repo secret the synth step reads. Documented so consumers can pick their own naming. |

A `synthesis-model` input is deliberately omitted from v1; the composite hardcodes Haiku 4.5 (see "Model choice" below). Add it as a follow-up if multi-model support proves necessary.

### audit-pr-synth composite action

New action at `.github/actions/audit-pr-synth/action.yml`. Inputs:

| Input | Source | Purpose |
|---|---|---|
| `raw-comment-path` | `${{ steps.render.outputs.comment-path }}` | The markdown the renderer produced. Used as the fallback comment body if synthesis fails. |
| `catalog-path` | `${{ steps.audit.outputs.catalog-path }}` | The full catalog JSON. Not sent to the LLM directly — used by the prep substep to extract a touched-scoped row subset. |
| `touched-json` | `${{ steps.touched.outputs.touched-json }}` | The PR's touched-file list (already produced earlier in the workflow). |
| `pr-title` | `${{ github.event.pull_request.title }}` | Short context for the prompt. |
| `pr-body` | `${{ github.event.pull_request.body }}` | Truncated to ~500 chars for the prompt. Optional. |
| `api-key` | `${{ secrets[inputs.synthesis-secret-name] }}` | The LLM API key. |

Outputs:

| Output | Purpose |
|---|---|
| `synthesized-comment-path` | Path to the markdown to post. On success: synthesized prose. On any failure (no key, API error, timeout, empty output): the raw comment passthrough. |
| `synthesis-status` | `synthesized`, `passthrough-no-key`, `passthrough-api-error`, or `passthrough-empty`. Emitted to step summary so consumers can debug. |

Internally the action:

1. Reads the catalog, filters to rows whose `members[]` intersect the touched set (the same filter the renderer applies). Keeps only `shape: cluster` and `shape: pair` rows; drops `shape: metric` (the touched-window-debt-summary roll-up is already incorporated as cluster context).
2. If zero rows remain → emit the existing "_No structural impact_" notice as the comment, exit with `synthesis-status=passthrough-empty`. No API call.
3. Otherwise, build the prompt (template below), call the LLM with a hard 30-second timeout and a 2000-output-token cap.
4. On success: write the response to `synthesized-comment-path`, set status to `synthesized`.
5. On any error (HTTP error, timeout, empty body, key missing): write the raw comment to `synthesized-comment-path`, set status accordingly. **The comment always posts** — fail-quiet matches the pre-commit hook's invariant from CLAUDE.md ("a blocking warning trains users to `--no-verify`").

### Prompt sketch (v1)

System:

> You are a code review assistant summarizing structural analysis findings for a pull request reviewer. The analysis was produced deterministically by an AST-based pipeline. You will be given (a) the PR title and short description, (b) the list of files the PR touched, and (c) a JSON array of cluster findings, where each finding describes a structural pattern in the codebase and the specific sites where the pattern appears. Some sites are marked `touched: true` — those are the files this PR modified.
>
> Write a short markdown comment (5-15 lines, no preamble) addressed to the reviewer. For each cluster, state in one or two sentences what the pattern is, which touched file participates, and what the reviewer should consider: propagate the change to the other sites, leave the pattern alone, consolidate, or split. Do not invent file names, line numbers, or code that is not in the input. Do not suggest patches. If a finding has no clear reviewer action, omit it rather than padding. If after consideration there is no actionable finding, output exactly: `_No actionable structural concerns from the touched files._`

User:

> PR title: `{pr_title}`
> PR description: `{pr_body_truncated_500}`
> Touched files:
> `{touched_files_list}`
>
> Cluster findings (JSON projection — `query_name`, `description`, `member_count`, and `members[]` with `file`/`line`/`name`/`kind`/`touched_in_window` only):
> `{cluster_rows_projection_json}`

The composite action stores the prompt template alongside the action so it can be reviewed and revised independently. The rows JSON sent to the LLM is a deliberate projection that drops anything not relevant to prose generation: catalog metadata, internal envelope fields, shape signatures used for matching. Only `query_name`, `description` (from query frontmatter), `members[]` with `file/line/name/kind/touched_in_window`, and `member_count` are forwarded. The projection is built by the composite, not the renderer — the renderer's output keeps its current shape so the artifact-upload path is unchanged.

### Model choice (v1: Haiku 4.5)

Haiku 4.5 — claude-haiku-4-5-20251001 — is plenty for prose generation over a structured prompt with no reasoning component. Per-call cost projection at typical PR scale (2-8 clusters, ~5KB prompt, ~1KB response) lands in the cent-or-two range; even high-activity repos cap monthly cost at a few dollars. Latency is well under the 30s timeout. Promoting to Sonnet only earns its keep if prose quality is materially weak — defer until evaluated, do not over-spec the v1.

### Fail-quiet behavior

Every error path in the synth composite resolves to "post the raw comment instead." Specifically:

| Failure | Behavior |
|---|---|
| `enable-synthesis: false` | Skip composite entirely. Raw comment posts. |
| `api-key` secret unset / empty | Skip composite, log `synthesis-status=passthrough-no-key` to step summary. Raw comment posts. |
| HTTP error from API | Log status + first 200 chars of body to step summary. Raw comment posts. |
| Timeout (30s) | Log timeout to step summary. Raw comment posts. |
| Empty/whitespace response | Log to step summary. Raw comment posts. |
| Filtered catalog has zero touched-intersecting rows | Skip API call. Post the "_No structural impact_" notice. |

The reviewer should never see a missing comment because synthesis failed. They should never see an apologetic "synthesis failed, here's the raw report" wrapper either — that adds chatter without adding signal. Just post the raw comment as if synthesis were off, and log the failure to the workflow step summary for the operator.

## Privacy and security

Enabling synthesis sends to the LLM provider:

- The PR title and (truncated) body.
- The list of file paths the PR touched (paths only, no contents).
- Per-cluster JSON rows: query name, query description, and `members[]` entries containing `file` (path), `line` (number), `name` (symbol identifier), `kind` (e.g., `interface`, `function`).

It does NOT send:

- File contents, diff hunks, or source code.
- Any catalog row not in a touched-intersecting cluster.
- Repo or org names beyond what the file paths reveal.
- Any GitHub token or secret.

Consumer-repo operators evaluating opt-in should understand: file paths and symbol names leave their CI runner and reach the configured LLM provider. For many repos this is fine; for some (regulated code, embargoed work) it is not. The default-off posture lets each consumer decide explicitly.

The composite documents this in its README. The `enable-synthesis: true` setting is a deliberate signal of consent.

## Companion fix (in the same PR, or a chained one)

`internal/cli/report_pr_comment.go:160-182` — the `rowIsTouched` switch's `case "metric": return true` blanket-pass. Two implementations were considered:

1. **Declarative opt-in in the jq query.** Add a frontmatter convention: `# pr-comment: touched-aware` at the top of `touched-window-debt-summary.jq`. The Go side parses the frontmatter and treats only opt-in metric queries as pass-through.
2. **Code-side allowlist.** A `metricQueriesTouchedAware = map[string]bool{"touched-window-debt-summary": true}` in `report_pr_comment.go`. Policy lives in Go.

**Decision: option 2.** Option 1 introduces a brand-new frontmatter convention that no other query consumes today and that this single allowlist would have to motivate alone. Per the project's "no abstractions beyond what the task requires" rule, that's premature. The Go-side allowlist is three lines, lives next to the switch statement that consults it, and is trivially extensible if a second touched-aware metric query appears. If the frontmatter idiom later earns its keep (e.g., a "skip in pre-commit hook" flag or a "deprecated, do not include" flag — both plausible but not currently needed), the allowlist refactors into it with no behavior change.

The implementation: extend `rowIsTouched`'s `case "metric":` branch to consult the allowlist. Rows from `touched-window-debt-summary` continue to pass through (the query self-filters via its `touched_clusters[]` payload). Rows from `shape-sig-frequency`, `migration-progress`, `coverage`, `preflight-versions` are dropped from PR-comment output when `--touched` is set. Those queries remain runnable directly and remain available in the workflow artifact.

This fix is necessary regardless of whether synthesis ships — without it the synthesizer's prompt would include 19 useless histograms on YAML-only PRs and the LLM would either ignore them (wasted tokens) or hallucinate prose about them (wrong output). Fix metric-bypass before or with synthesis; do not ship synthesis without it.

## Out of scope (deliberately)

- **Diff-aware synthesis.** v1 sends only file paths + cluster intersections. Sending actual diff hunks would let the LLM say "you renamed `getFoo` to `loadFoo` but four siblings still use `get*`" — much sharper prose. It also ~10x's the token budget and increases hallucination risk. Defer to v2 after v1 prose quality is evaluated against real PRs.
- **Multi-model support.** No `synthesis-model` input; the composite hardcodes Haiku. Add later if needed.
- **Local synthesis.** The pre-commit hook (`hooks/pre-commit-audit.mjs`) stays raw. Local invocations do not call out to an LLM. The hook's existing fail-quiet `code-audit: skipped` invariant is unchanged.
- **Custom prompts per consumer.** No prompt override input in v1. The review of this plan asked whether an optional `prompt-template-path` input belongs in v1 to let consumers iterate locally if the canonical prompt underperforms. Rejected for v1 for a specific reason: dogfooding on this repo's selftest is the v1 evaluation surface, and if every consumer can fork the prompt before that signal lands, the canonical prompt never gets the feedback needed to converge. Consumers who find the canonical prompt weak should report it (issue + sample PR) rather than route around it. If a real specialization need surfaces during dogfooding ("our team needs security-cluster framing"), add the input deliberately in v2 with documented semantics rather than retrofitting it under field pressure. Bias on this one: prefer the slower iteration loop that produces one well-tuned prompt over the faster loop that produces N divergent ones.
- **Evaluation harness.** No automated eval of prose quality in v1. Operator judgment after dogfooding for ~2 weeks is the gate. If prose quality is consistently weak, build an eval before iterating; do not iterate blind.

## Open questions

1. **Provider lock-in.** v1 calls Anthropic directly. Should the composite support OpenAI/local-model providers behind an abstraction? *Recommendation: no, not in v1.* The Anthropic API is the only one the project has any reason to prefer (cost + quality + the project's existing context), and abstracting before there are two real consumers is premature.
2. **Should the raw artifact remain uploaded when synthesis succeeds?** *Yes.* The artifact is the operator's audit trail. If a reviewer disputes the synthesized prose, the raw rendering is the source of truth.
3. **Sticky-comment marker.** The current marker `<!-- code-audit-pipeline-v1 -->` is shared across both modes; synthesized and raw comments overwrite each other across pushes. *Keep this.* The alternative — two markers, two sticky comments — clutters PR conversation.
4. **What if `enable-synthesis: true` but the configured secret name resolves empty?** *Already covered:* log `passthrough-no-key`, post raw. This is the common misconfiguration path; the synth-status log line tells the operator exactly what to fix.

## Roll-out

1. PR adds the synth composite, the workflow inputs, the metric-bypass fix, the prompt template, and a `docs/integrations/pr-comment-synthesis.md` user guide.
2. Selftest in this repo enables synthesis on its own PR-comment workflow (the project consumes its own audit). This is the dogfooding surface.
3. Release as `v0.4.0` (minor bump — new opt-in feature, no breaking change). Consumers on `@v0.3.x` are unaffected until they bump.
4. After ~2 weeks of selftest usage, decide: keep, iterate the prompt, or revert. Revert path is clean — set `enable-synthesis: false` (the default), the composite is a no-op.

Versioning policy: any prompt change after v0.4.0 ships is a patch bump (`v0.4.1` etc.) — the prompt is part of the action's behavior contract for opted-in consumers. Consumers pinning `@v0.4` track patch bumps automatically; consumers pinning `@v0.4.0` exactly do not. The `pr-comment-reusable.yml@v1` floating tag continues to point at the latest minor in the v1 line; consumers wanting deterministic prose across runs should pin to an exact tag. Because v1 has no prompt override input, every consumer at the same pinned version receives the same prompt — making prompt-quality regressions easy to spot and revert.

## Acceptance criteria

- `enable-synthesis: false` (the default) on `pr-comment-reusable.yml@<new-release>` produces byte-identical output to `@v0.3.3` for the same PR, except for the version line in the comment footer.
- `enable-synthesis: true` with a valid API key produces a synthesized comment on a PR with at least one touched-intersecting cluster.
- `enable-synthesis: true` with no touched-intersecting clusters produces the "_No structural impact_" notice without calling the LLM API.
- `enable-synthesis: true` with the API key unset posts the raw comment and logs `passthrough-no-key`.
- The metric-bypass fix is verified by Go unit tests in `internal/cli/report_pr_comment_test.go` following the existing `TestFilterRowsByTouched_*` table-test pattern: at least one case proves `shape-sig-frequency` and similar global metric queries are dropped when `--touched` is set; at least one case proves `touched-window-debt-summary` rows still pass through. No new test harness or fixture format required.
- The raw artifact upload happens in all modes.
- `docs/integrations/pr-comment-synthesis.md` exists and documents: how to enable, what data leaves the runner, fail-quiet behavior, and the prompt's text.

## Companion / follow-up issues

- #273 (already filed) — refactor `audit-pr-comment` composite to take `audit-core` outputs as inputs. Unblocks composite-level testing; this synthesis work doesn't depend on it but would compose more cleanly after it lands.
- New follow-up after v1 lands: diff-aware synthesis (v2). Sketch only after evaluating v1 prose quality on real PRs.
- New follow-up after v1 lands: prompt-template override input, if any consumer surfaces a real specialization need.
