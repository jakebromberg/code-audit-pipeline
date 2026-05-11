#!/usr/bin/env node
// v2-analysis.mjs — measurement protocol for the V2 dj-site divergence experiment.
//
// Reads /tmp/wxyc-audit-v2/<condition>/trial-N/output.json across C2–C5 (C1 outputs are Markdown
// and analyzed separately) and emits the metrics specified in the V2 methodology doc:
//
//   - intra-condition pairwise Jaccard on cluster_id sets (mean / min / max / std)
//   - cross-condition union coverage and pairwise Jaccard
//   - clusters covered only by one condition (the diagnostic for substrate-widening recall)
//   - severity-calibration drift (clusters where modal severity disagrees across conditions)
//   - per-trial finding counts and emit-rate distribution
//
// Usage: node v2-analysis.mjs                      # writes JSON + Markdown summary
//        node v2-analysis.mjs --json-only          # JSON only, to stdout

import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const BASE = '/tmp/wxyc-audit-v2';
const CONDITIONS = ['C2', 'C3', 'C4', 'C5'];

function jaccard(a, b) {
  const sa = new Set(a), sb = new Set(b);
  const intersect = [...sa].filter((x) => sb.has(x)).length;
  const union = new Set([...sa, ...sb]).size;
  return union === 0 ? 0 : intersect / union;
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
    catch (e) {
      process.stderr.write(`  FAIL ${cond}/${entry}: ${e.message}\n`);
      continue;
    }
    if (!Array.isArray(findings)) {
      process.stderr.write(`  FAIL ${cond}/${entry}: not an array\n`);
      continue;
    }
    trials.push({ trial: entry, findings });
  }
  return trials;
}

const trialsByCondition = {};
for (const c of CONDITIONS) trialsByCondition[c] = loadTrials(c);

const stats = (arr) => {
  if (arr.length === 0) return { n: 0, mean: 0, median: 0, min: 0, max: 0, std: 0 };
  const sorted = [...arr].sort((a, b) => a - b);
  const mean = arr.reduce((s, v) => s + v, 0) / arr.length;
  const median = sorted[Math.floor(sorted.length / 2)];
  const std = Math.sqrt(arr.reduce((s, v) => s + (v - mean) ** 2, 0) / arr.length);
  return { n: arr.length, mean, median, min: Math.min(...arr), max: Math.max(...arr), std };
};

// --- 1. Intra-condition pairwise Jaccard ---
const intraJaccard = {};
const findingCountsPerCondition = {};
for (const c of CONDITIONS) {
  const trials = trialsByCondition[c];
  const setsPerTrial = trials.map((t) => new Set(t.findings.map((f) => f.cluster_id)));
  findingCountsPerCondition[c] = trials.map((t) => t.findings.length);
  const pairs = [];
  for (let i = 0; i < setsPerTrial.length; i++) {
    for (let j = i + 1; j < setsPerTrial.length; j++) {
      pairs.push(jaccard(setsPerTrial[i], setsPerTrial[j]));
    }
  }
  intraJaccard[c] = { stats: stats(pairs), pairs, trialCount: trials.length };
}

// --- 2. Cross-condition union coverage and Jaccard ---
const coveragePerCondition = {};
const allClusters = new Set();
for (const c of CONDITIONS) {
  const cov = new Set();
  for (const t of trialsByCondition[c]) for (const f of t.findings) cov.add(f.cluster_id);
  coveragePerCondition[c] = cov;
  for (const x of cov) allClusters.add(x);
}

const crossJaccard = {};
for (let i = 0; i < CONDITIONS.length; i++) {
  for (let j = i + 1; j < CONDITIONS.length; j++) {
    const c1 = CONDITIONS[i], c2 = CONDITIONS[j];
    crossJaccard[`${c1}_vs_${c2}`] = jaccard(coveragePerCondition[c1], coveragePerCondition[c2]);
  }
}

// --- 3. Only-in-X analyses ---
const onlyInC4_notC3 = [...coveragePerCondition.C4].filter((x) => !coveragePerCondition.C3.has(x));
const onlyInC3_notC4 = [...coveragePerCondition.C3].filter((x) => !coveragePerCondition.C4.has(x));
const onlyInC2_notC3 = [...coveragePerCondition.C2].filter((x) => !coveragePerCondition.C3.has(x));
const onlyInC3_notC2 = [...coveragePerCondition.C3].filter((x) => !coveragePerCondition.C2.has(x));

// --- 4. Severity calibration ---
const modalSeverity = {};
for (const c of CONDITIONS) {
  modalSeverity[c] = {};
  const sevsByCluster = {};
  for (const t of trialsByCondition[c]) {
    for (const f of t.findings) {
      (sevsByCluster[f.cluster_id] ??= []).push(f.severity);
    }
  }
  for (const [cid, sevs] of Object.entries(sevsByCluster)) {
    const counts = {};
    for (const s of sevs) counts[s] = (counts[s] || 0) + 1;
    modalSeverity[c][cid] = Object.entries(counts).sort((a, b) => b[1] - a[1])[0][0];
  }
}
const calibrationDrift = [];
for (const cid of allClusters) {
  const sevsByCond = {};
  for (const c of CONDITIONS) if (modalSeverity[c][cid]) sevsByCond[c] = modalSeverity[c][cid];
  const sevs = new Set(Object.values(sevsByCond));
  if (Object.keys(sevsByCond).length >= 2 && sevs.size > 1) {
    calibrationDrift.push({ cluster_id: cid, severity_by_condition: sevsByCond });
  }
}

// --- 5. Predictions check ---
const predictions = {
  'C2 intra-pair Jaccard ≥ 0.75': intraJaccard.C2?.stats.mean >= 0.75,
  'C3 intra-pair Jaccard ≥ 0.85': intraJaccard.C3?.stats.mean >= 0.85,
  'C3 ∪ C4 coverage Jaccard ≥ 0.70': crossJaccard.C3_vs_C4 >= 0.70,
  'C5 intra-pair Jaccard ≥ C3': (intraJaccard.C5?.stats.mean || 0) >= (intraJaccard.C3?.stats.mean || 0),
};

// --- Output ---
const summary = {
  conditions: CONDITIONS,
  trial_counts: Object.fromEntries(CONDITIONS.map((c) => [c, trialsByCondition[c].length])),
  finding_counts_per_trial: findingCountsPerCondition,
  intra_condition_jaccard: Object.fromEntries(
    CONDITIONS.map((c) => [c, intraJaccard[c].stats])
  ),
  cross_condition_jaccard: crossJaccard,
  union_size: allClusters.size,
  coverage_per_condition: Object.fromEntries(
    CONDITIONS.map((c) => [c, coveragePerCondition[c].size])
  ),
  only_C4_not_C3_count: onlyInC4_notC3.length,
  only_C3_not_C4_count: onlyInC3_notC4.length,
  only_C2_not_C3_count: onlyInC2_notC3.length,
  only_C3_not_C2_count: onlyInC3_notC2.length,
  severity_drift_count: calibrationDrift.length,
  severity_drift_samples: calibrationDrift.slice(0, 20),
  only_C4_not_C3_samples: onlyInC4_notC3.slice(0, 20),
  only_C3_not_C4_samples: onlyInC3_notC4.slice(0, 20),
  predictions,
};

writeFileSync(join(BASE, 'analysis-summary.json'), JSON.stringify(summary, null, 2));

// Markdown summary for human reading
let md = `# V2 Experiment — Measurement Summary\n\nGenerated ${new Date().toISOString()}\n\n`;
md += `## Trial counts\n\n`;
for (const c of CONDITIONS) {
  md += `- **${c}**: ${trialsByCondition[c].length} trials. Findings per trial: ${findingCountsPerCondition[c].join(', ')}\n`;
}
md += `\n## Intra-condition Jaccard (cluster_id sets across trials)\n\n`;
md += `| Condition | trials | pairs | mean | median | min | max | std |\n|---|---|---|---|---|---|---|---|\n`;
for (const c of CONDITIONS) {
  const s = intraJaccard[c].stats;
  md += `| ${c} | ${intraJaccard[c].trialCount} | ${s.n} | ${s.mean.toFixed(2)} | ${s.median.toFixed(2)} | ${s.min.toFixed(2)} | ${s.max.toFixed(2)} | ${s.std.toFixed(2)} |\n`;
}
md += `\n## Cross-condition Jaccard (union coverage)\n\n`;
md += `| Pair | Jaccard |\n|---|---|\n`;
for (const [k, v] of Object.entries(crossJaccard)) md += `| ${k.replace('_vs_', ' vs ')} | ${v.toFixed(2)} |\n`;

md += `\n## Union coverage\n\n- Total unique cluster_ids across all conditions: **${allClusters.size}**\n`;
for (const c of CONDITIONS) {
  md += `- ${c}: ${coveragePerCondition[c].size} (${(coveragePerCondition[c].size / allClusters.size * 100).toFixed(0)}%)\n`;
}

md += `\n## Recall diagnostics\n\n`;
md += `- In C4 (cold) but not C3 (widened): **${onlyInC4_notC3.length}** clusters\n`;
md += `- In C3 (widened) but not C4 (cold): **${onlyInC3_notC4.length}** clusters\n`;
md += `- In C2 (narrow) but not C3 (widened): **${onlyInC2_notC3.length}** clusters\n`;
md += `- In C3 (widened) but not C2 (narrow): **${onlyInC3_notC2.length}** clusters\n`;

md += `\n## Severity calibration drift\n\n- ${calibrationDrift.length} clusters have modal-severity disagreement across ≥2 conditions.\n`;
if (calibrationDrift.length > 0) {
  md += `\n### Sample (first 10):\n\n`;
  for (const d of calibrationDrift.slice(0, 10)) {
    md += `- \`${d.cluster_id}\`: ${Object.entries(d.severity_by_condition).map(([c, s]) => `${c}=${s}`).join(', ')}\n`;
  }
}

md += `\n## Predictions to falsify\n\n`;
md += `| Prediction | Result |\n|---|---|\n`;
for (const [k, v] of Object.entries(predictions)) {
  md += `| ${k} | ${v ? 'YES' : 'NO'} |\n`;
}

writeFileSync(join(BASE, 'analysis-summary.md'), md);

if (process.argv.includes('--json-only')) {
  process.stdout.write(JSON.stringify(summary, null, 2));
} else {
  process.stderr.write(md);
  process.stderr.write(`\nWrote ${BASE}/analysis-summary.{json,md}\n`);
}
