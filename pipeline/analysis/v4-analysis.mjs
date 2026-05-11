#!/usr/bin/env node
// v3-analysis.mjs — per-plant recall + intra-condition Jaccard for the V3 experiment.
//
// Reads /tmp/wxyc-audit-v4/<condition>/trial-N/output.json across C2, C3, C4
// and scores each against the manifest of 20 plants. For each plant the canonical
// cluster_id is paired with a set of acceptable equivalents (different category
// prefix, reversed pair order, derivative pairings created by other plants).

import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const BASE = '/tmp/wxyc-audit-v4';
const CONDITIONS = ['C2', 'C3', 'C4'];

// Plant manifest with acceptable cluster_id variants for fuzzy matching.
// Each plant has a `id`, `category`, and `accept` — a list of canonical-form
// cluster_ids; any of which counts as a detection.
const PLANTS = [
  { id: 1, category: 'exact-duplicates', accept: [
    'exact-duplicates:AuthSessionTokenPayload+BetterAuthJwtPayload',
  ]},
  { id: 2, category: 'exact-duplicates', accept: [
    'exact-duplicates:AlbumCardProps+AlbumPanelCardProps',
  ]},
  { id: 3, category: 'exact-duplicates', accept: [
    'exact-duplicates:ArtistPanelHeaderProps+LabelPanelHeaderProps+RightbarPanelContainerProps+TrackPanelHeaderProps',
  ]},
  { id: 4, category: 'exact-duplicates', accept: [
    'exact-duplicates:PlaylistSearchRowProps+RosterSearchRowProps',
  ]},
  { id: 5, category: 'cross-package-shadows', accept: [
    'cross-package-shadows:Album',
    'name-collisions:Album',
  ]},
  { id: 6, category: 'cross-package-shadows', accept: [
    'cross-package-shadows:BinEntry',
    'name-collisions:BinEntry',
  ]},
  { id: 7, category: 'cross-package-shadows', accept: [
    'cross-package-shadows:DiscogsArtistRef',
    'name-collisions:DiscogsArtistRef',
  ]},
  { id: 8, category: 'cross-package-shadows', accept: [
    'cross-package-shadows:ShowPeek',
    'name-collisions:ShowPeek',
  ]},
  { id: 9, category: 'subset-pairs', accept: [
    'subset-pairs:AuthJwtBasicClaims__BetterAuthJwtPayload',
    'subset-pairs:AuthJwtBasicClaims__AuthSessionTokenPayload',
  ]},
  { id: 10, category: 'subset-pairs', accept: [
    'subset-pairs:ExperienceConfigPreview__ExperienceConfig',
  ]},
  { id: 11, category: 'subset-pairs', accept: [
    'subset-pairs:AlbumCardCompactProps__AlbumCardProps',
    'subset-pairs:AlbumCardCompactProps__AlbumPanelCardProps',
  ]},
  { id: 12, category: 'subset-pairs', accept: [
    'subset-pairs:BinColorPreview__BinColorSet',
  ]},
  { id: 13, category: 'near-duplicates', accept: [
    'near-duplicates:AuthSessionJwtClaims+BetterAuthJwtPayload',
    'near-duplicates:AuthSessionJwtClaims+AuthSessionTokenPayload',
  ]},
  { id: 14, category: 'near-duplicates', accept: [
    'near-duplicates:PlaylistFilterRowProps+PlaylistSearchRowProps',
    'near-duplicates:PlaylistFilterRowProps+RosterSearchRowProps',
  ]},
  { id: 15, category: 'near-duplicates', accept: [
    'near-duplicates:BarAudioVisualizerProps+GradientAudioVisualizerProps',
  ]},
  { id: 16, category: 'near-duplicates', accept: [
    'near-duplicates:SearchCatalogQueryParams+SearchCatalogQueryParamsExtended',
  ]},
  { id: 17, category: 'substrate-gap', accept: [
    'function-duplicates:betterAuthSessionToAuthenticationData+betterAuthSessionToAuthenticationDataLite',
    'function-duplicates:betterAuthSessionToAuthenticationDataLite+betterAuthSessionToAuthenticationData',
  ]},
  { id: 18, category: 'substrate-gap', accept: [
    'file-duplicates:lib/features/playlist-search/utils.ts+src/playlist-search/utils.ts',
    'file-duplicates:src/playlist-search/utils.ts+lib/features/playlist-search/utils.ts',
  ]},
  { id: 19, category: 'substrate-gap', accept: [
    'cross-package-near-duplicates:AddScheduleShiftRequest+ScheduleShiftEntry',
    'cross-package-near-duplicates:ScheduleShiftEntry+AddScheduleShiftRequest',
    'near-duplicates:AddScheduleShiftRequest+ScheduleShiftEntry',
  ]},
  { id: 20, category: 'substrate-gap', accept: [
    'subset-pairs:RecordingDraft__RecordingDraftExtended',
  ]},
];

// Tolerant cluster_id matcher. Treats `name-collisions:X` ≡ `cross-package-shadows:X`,
// `near-duplicates:A+B` ≡ `near-duplicates:B+A`, strips the absolute worktree path
// prefix from file-duplicates cluster_ids before comparison.
const PATH_PREFIX_RE = /(?:\/Users\/[^/]+\/Developer\/WXYC\/dj-site(?:-v3-plants|-v4-flat)?|\/tmp\/dj-site-v4-flat)\//g;
function normalizeCid(cid) {
  if (typeof cid !== 'string') return cid;
  return cid.replace(PATH_PREFIX_RE, '');
}
function semanticKey(cid) {
  const norm = normalizeCid(cid);
  if (typeof norm !== 'string') return null;
  const [prefix, rest = ''] = norm.split(':', 2);
  const parts = rest.split(/[+]|__/).map((s) => s.trim()).filter(Boolean);
  return `${prefix}::${[...new Set(parts)].sort().join('|')}`;
}

function namesOf(cid) {
  const norm = normalizeCid(cid);
  const [prefix, rest = ''] = norm.split(':', 2);
  const names = new Set(rest.split(/[+]|__/).map((s) => s.trim()).filter(Boolean));
  return { prefix, names };
}
function clusterMatchesPlant(cid, plant) {
  if (plant.accept.includes(cid)) return true;
  const wantKeys = plant.accept.map(semanticKey);
  if (wantKeys.includes(semanticKey(cid))) return true;
  // Superset match: an emitted N-way cluster covers a plant's required pair if
  // it has the same prefix and contains all required names. Catches the C4
  // habit of merging multiple related drifts into a single multi-name finding
  // (e.g., function-duplicates:fnA+fnB+fnC covers plant requiring fnA+fnB).
  const emitted = namesOf(cid);
  for (const accept of plant.accept) {
    const want = namesOf(accept);
    if (emitted.prefix !== want.prefix) continue;
    let allPresent = true;
    for (const n of want.names) { if (!emitted.names.has(n)) { allPresent = false; break; } }
    if (allPresent) return true;
  }
  return false;
}

function loadTrials(cond) {
  const trials = [];
  const dir = join(BASE, cond);
  if (!existsSync(dir)) return trials;
  for (const entry of readdirSync(dir).sort()) {
    if (!entry.startsWith('trial-')) continue;
    const out = join(dir, entry, 'output.json');
    if (!existsSync(out)) continue;
    let findings;
    try { findings = JSON.parse(readFileSync(out, 'utf8')); }
    catch (e) { process.stderr.write(`  PARSE FAIL ${cond}/${entry}: ${e.message}\n`); continue; }
    if (!Array.isArray(findings)) { process.stderr.write(`  NOT ARRAY ${cond}/${entry}\n`); continue; }
    trials.push({ trial: entry, findings });
  }
  return trials;
}

function jaccard(a, b) {
  const sa = new Set(a), sb = new Set(b);
  const inter = [...sa].filter((x) => sb.has(x)).length;
  const union = new Set([...sa, ...sb]).size;
  return union === 0 ? 0 : inter / union;
}

const stats = (arr) => {
  if (arr.length === 0) return { n: 0, mean: 0, median: 0, min: 0, max: 0, std: 0 };
  const sorted = [...arr].sort((a, b) => a - b);
  const mean = arr.reduce((s, v) => s + v, 0) / arr.length;
  const median = sorted[Math.floor(sorted.length / 2)];
  const std = Math.sqrt(arr.reduce((s, v) => s + (v - mean) ** 2, 0) / arr.length);
  return { n: arr.length, mean, median, min: Math.min(...arr), max: Math.max(...arr), std };
};

const trialsByCondition = {};
for (const c of CONDITIONS) trialsByCondition[c] = loadTrials(c);

// Per-plant per-trial recall matrix
const detectionMatrix = {};
for (const c of CONDITIONS) {
  detectionMatrix[c] = trialsByCondition[c].map((trial) => {
    return PLANTS.map((p) => trial.findings.some((f) => clusterMatchesPlant(f.cluster_id, p)));
  });
}

// Per-plant recall per condition (fraction of trials that detected it)
const plantRecall = {};
for (const c of CONDITIONS) {
  plantRecall[c] = PLANTS.map((p, i) => {
    const trials = detectionMatrix[c];
    if (trials.length === 0) return 0;
    const detected = trials.filter((row) => row[i]).length;
    return detected / trials.length;
  });
}

// Per-category recall: avg per-plant-recall over plants in that category
const CATEGORIES = ['exact-duplicates', 'cross-package-shadows', 'subset-pairs', 'near-duplicates', 'substrate-gap'];
const categoryRecall = {};
for (const c of CONDITIONS) {
  categoryRecall[c] = {};
  for (const cat of CATEGORIES) {
    const inCat = PLANTS.map((p, i) => p.category === cat ? plantRecall[c][i] : null).filter((x) => x !== null);
    categoryRecall[c][cat] = inCat.reduce((s, v) => s + v, 0) / inCat.length;
  }
}

// Intra-condition Jaccard on full cluster_id sets (V2-style)
const intraFullJaccard = {};
for (const c of CONDITIONS) {
  const setsPerTrial = trialsByCondition[c].map((t) => new Set(t.findings.map((f) => f.cluster_id)));
  const pairs = [];
  for (let i = 0; i < setsPerTrial.length; i++) {
    for (let j = i + 1; j < setsPerTrial.length; j++) pairs.push(jaccard(setsPerTrial[i], setsPerTrial[j]));
  }
  intraFullJaccard[c] = stats(pairs);
}

// Intra-condition Jaccard on plant-cluster_id sets only (which plants each trial caught)
const intraPlantJaccard = {};
for (const c of CONDITIONS) {
  const setsPerTrial = detectionMatrix[c].map((row) => {
    const detected = new Set();
    row.forEach((hit, i) => { if (hit) detected.add(PLANTS[i].id); });
    return detected;
  });
  const pairs = [];
  for (let i = 0; i < setsPerTrial.length; i++) {
    for (let j = i + 1; j < setsPerTrial.length; j++) pairs.push(jaccard(setsPerTrial[i], setsPerTrial[j]));
  }
  intraPlantJaccard[c] = stats(pairs);
}

// Finding counts
const findingCounts = {};
for (const c of CONDITIONS) findingCounts[c] = trialsByCondition[c].map((t) => t.findings.length);

const summary = {
  conditions: CONDITIONS,
  trial_counts: Object.fromEntries(CONDITIONS.map((c) => [c, trialsByCondition[c].length])),
  finding_counts_per_trial: findingCounts,
  intra_full_jaccard: intraFullJaccard,
  intra_plant_jaccard: intraPlantJaccard,
  plant_recall: Object.fromEntries(CONDITIONS.map((c) => [c, plantRecall[c]])),
  category_recall: categoryRecall,
  plants_meta: PLANTS.map(({ id, category }) => ({ id, category })),
};

writeFileSync(join(BASE, 'analysis-summary.json'), JSON.stringify(summary, null, 2));

// Markdown summary
let md = `# V3 Experiment — Measurement Summary\n\nGenerated ${new Date().toISOString()}\n\n`;
md += `## Trial counts\n\n`;
for (const c of CONDITIONS) md += `- **${c}**: ${trialsByCondition[c].length} trials. Findings per trial: ${findingCounts[c].join(', ')}\n`;

md += `\n## Intra-condition Jaccard on full cluster_id sets\n\n`;
md += `| Condition | trials | pairs | mean | min | max | std |\n|---|---|---|---|---|---|---|\n`;
for (const c of CONDITIONS) {
  const s = intraFullJaccard[c];
  md += `| ${c} | ${trialsByCondition[c].length} | ${s.n} | ${s.mean.toFixed(2)} | ${s.min.toFixed(2)} | ${s.max.toFixed(2)} | ${s.std.toFixed(2)} |\n`;
}

md += `\n## Intra-condition Jaccard on plant-only sets\n\n`;
md += `| Condition | trials | pairs | mean | min | max | std |\n|---|---|---|---|---|---|---|\n`;
for (const c of CONDITIONS) {
  const s = intraPlantJaccard[c];
  md += `| ${c} | ${trialsByCondition[c].length} | ${s.n} | ${s.mean.toFixed(2)} | ${s.min.toFixed(2)} | ${s.max.toFixed(2)} | ${s.std.toFixed(2)} |\n`;
}

md += `\n## Per-category recall (fraction of plants detected, averaged over trials and plants)\n\n`;
md += `| Category | C2 (narrow) | C3 (widened) | C4 (cold) |\n|---|---|---|---|\n`;
for (const cat of CATEGORIES) {
  md += `| ${cat} | ${(categoryRecall.C2[cat] * 100).toFixed(0)}% | ${(categoryRecall.C3[cat] * 100).toFixed(0)}% | ${(categoryRecall.C4[cat] * 100).toFixed(0)}% |\n`;
}

md += `\n## Per-plant recall (detected in N/total trials)\n\n`;
md += `| # | Category | C2 | C3 | C4 |\n|---|---|---|---|---|\n`;
PLANTS.forEach((p, i) => {
  const fmt = (c) => {
    const r = plantRecall[c][i];
    const detected = detectionMatrix[c].filter((row) => row[i]).length;
    const total = detectionMatrix[c].length;
    return `${detected}/${total} (${(r * 100).toFixed(0)}%)`;
  };
  md += `| ${p.id} | ${p.category} | ${fmt('C2')} | ${fmt('C3')} | ${fmt('C4')} |\n`;
});

md += `\n## Predictions check\n\n`;
md += `| Prediction | Result |\n|---|---|\n`;
const checks = [
  ['C3 detects 4/4 exact-duplicates plants', categoryRecall.C3['exact-duplicates'] >= 1.0],
  ['C3 detects 4/4 cross-package-shadows plants', categoryRecall.C3['cross-package-shadows'] >= 1.0],
  ['C3 detects 4/4 subset-pairs plants', categoryRecall.C3['subset-pairs'] >= 1.0],
  ['C3 detects ≥3/4 near-duplicates plants', categoryRecall.C3['near-duplicates'] >= 0.75],
  ['C3 detects 0/4 substrate-gap plants', categoryRecall.C3['substrate-gap'] === 0],
  ['C4 detects ≥3/4 in each natural category', CATEGORIES.slice(0, 4).every((cat) => categoryRecall.C4[cat] >= 0.75)],
  ['C4 detects ≥3/4 substrate-gap plants', categoryRecall.C4['substrate-gap'] >= 0.75],
  ['C3 plant-only intra-trial Jaccard ≥ 0.95', intraPlantJaccard.C3.mean >= 0.95],
  ['C4 plant-only intra-trial Jaccard ≥ 0.50', intraPlantJaccard.C4.mean >= 0.50],
];
for (const [k, v] of checks) md += `| ${k} | ${v ? 'YES' : 'NO'} |\n`;

writeFileSync(join(BASE, 'analysis-summary.md'), md);
process.stderr.write(md);
process.stderr.write(`\nWrote ${BASE}/analysis-summary.{json,md}\n`);
