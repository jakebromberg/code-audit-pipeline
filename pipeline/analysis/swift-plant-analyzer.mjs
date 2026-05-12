#!/usr/bin/env node
// swift-plant-analyzer.mjs
//
// Reads the 8 cluster-query outputs produced from the planted wxyc-ios-64 catalog
// and reports per-plant surfacing. For each plant: which query (if any) it
// appeared in, and the matching line(s). Final summary tabulates recall per
// category and overall.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const QUERY_DIR = process.argv[2] || '/tmp/wxyc-ios-audit-planted/queries';

const queries = {
  exact:               readFileSync(join(QUERY_DIR, 'exact-duplicates.txt'), 'utf8'),
  nameCollisions:      readFileSync(join(QUERY_DIR, 'name-collisions.txt'), 'utf8'),
  subset:              readFileSync(join(QUERY_DIR, 'subset-pairs.txt'), 'utf8'),
  nearDup:             readFileSync(join(QUERY_DIR, 'near-duplicates-any.txt'), 'utf8'),
  shadow:              readFileSync(join(QUERY_DIR, 'cross-package-shadows-any.txt'), 'utf8'),
  shapeNearDup:        readFileSync(join(QUERY_DIR, 'cross-package-shape-near-duplicates-any.txt'), 'utf8'),
  functionDup:         readFileSync(join(QUERY_DIR, 'function-duplicates.txt'), 'utf8'),
  fileDup:             readFileSync(join(QUERY_DIR, 'file-duplicates.txt'), 'utf8'),
};

// Each plant: id, category, expected query, and a needle list. Surfacing means
// at least one needle appears in the expected query. needle is a regex string.
const plants = [
  // Exact duplicates: planted type ≡ source type (same shape, different name)
  { id:  1, cat: 'exact-duplicates',     query: 'exact',         needle: /BroadcastSource/ },
  { id:  2, cat: 'exact-duplicates',     query: 'exact',         needle: /StreamCacheSetup/ },
  { id:  3, cat: 'exact-duplicates',     query: 'exact',         needle: /ShaderPassDescriptor/ },
  { id:  4, cat: 'exact-duplicates',     query: 'exact',         needle: /AppContextSettings/ },

  // Cross-package shadows: same NAME in two packages
  { id:  5, cat: 'cross-package-shadows', query: 'shadow',       needle: /^RadioStation\s+\[\d+ packages/m },
  { id:  6, cat: 'cross-package-shadows', query: 'shadow',       needle: /^Logger\s+\[\d+ packages/m },
  { id:  7, cat: 'cross-package-shadows', query: 'shadow',       needle: /^LoadedTheme\s+\[\d+ packages/m },
  { id:  8, cat: 'cross-package-shadows', query: 'shadow',       needle: /^TimeShiftablePlayer\s+\[\d+ packages/m },

  // Subset-pairs: planted subset ⊂ source
  { id:  9, cat: 'subset-pairs',         query: 'subset',        needle: /RadioStationLite \[\d+ fields\] ⊂ RadioStation \[/ },
  { id: 10, cat: 'subset-pairs',         query: 'subset',        needle: /ThemeReference \[\d+ fields\] ⊂ LoadedTheme \[/ },
  { id: 11, cat: 'subset-pairs',         query: 'subset',        needle: /BasicConversionInfo \[\d+ fields\] ⊂ ConversionContext \[/ },
  { id: 12, cat: 'subset-pairs',         query: 'subset',        needle: /BasicTimeShifter \[\d+ fields\] ⊂ TimeShiftablePlayer \[/ },

  // Near-duplicates: Jaccard ≥ 0.7 across distinct names
  { id: 13, cat: 'near-duplicates',      query: 'nearDup',       needle: /EnhancedStreamerConfiguration/ },
  { id: 14, cat: 'near-duplicates',      query: 'nearDup',       needle: /GraphicsConfiguration/ },
  { id: 15, cat: 'near-duplicates',      query: 'nearDup',       needle: /AppContextRich/ },
  { id: 16, cat: 'near-duplicates',      query: 'nearDup',       needle: /RadioStationExtended/ },

  // Substrate-gap probes
  { id: 17, cat: 'substrate-gap',        query: 'functionDup',   needle: /hashSlug.*hashSlugLite|hashSlugLite.*hashSlug/ },
  { id: 18, cat: 'substrate-gap',        query: 'fileDup',       needle: /_Plant_StreamUtilities\.swift/ },
  { id: 19, cat: 'substrate-gap',        query: 'shapeNearDup',  needle: /Metadata:RenderPassSpec|Wallpaper:PassConfiguration.*RenderPassSpec/ },
  // Plant 20: extension-fragmented type. Expected to NOT surface with current substrate
  // (no extension-merging). Marked as expected-gap.
  { id: 20, cat: 'substrate-gap',        query: 'subset',        needle: /FragmentedConfig \[\d+ fields\] ⊂ UnifiedConfig \[/, expectedGap: true },
];

const results = plants.map((p) => {
  const queryText = queries[p.query];
  const matched = p.needle.test(queryText);
  const status = matched
    ? (p.expectedGap ? 'GAP-CLOSED' : 'SURFACED')
    : (p.expectedGap ? 'EXPECTED-GAP' : 'MISSED');
  return { ...p, matched, status };
});

// Per-category tally
const byCategory = {};
for (const r of results) {
  if (!byCategory[r.cat]) byCategory[r.cat] = { total: 0, surfaced: 0, expectedGaps: 0 };
  byCategory[r.cat].total++;
  if (r.matched) byCategory[r.cat].surfaced++;
  if (r.expectedGap) byCategory[r.cat].expectedGaps++;
}

// Output
console.log('Plant-recall results');
console.log('='.repeat(70));
console.log('');
console.log('Per-plant:');
console.log('');
for (const r of results) {
  const flag = r.status === 'SURFACED' ? '✓' :
               r.status === 'GAP-CLOSED' ? '✓✓' :
               r.status === 'EXPECTED-GAP' ? '∅' : '✗';
  console.log(`  ${flag} Plant ${String(r.id).padStart(2)}  [${r.cat.padEnd(22)}]  query=${r.query.padEnd(15)} ${r.status}`);
}
console.log('');
console.log('Per-category recall:');
console.log('');
for (const [cat, t] of Object.entries(byCategory)) {
  const realTotal = t.total - t.expectedGaps;
  const recall = realTotal > 0 ? (t.surfaced / realTotal) : 1;
  const pct = (recall * 100).toFixed(0);
  console.log(`  ${cat.padEnd(24)} ${t.surfaced}/${t.total} surfaced (${t.expectedGaps} expected-gap)   recall = ${pct}%`);
}
console.log('');
const totalSurfaced = results.filter((r) => r.matched).length;
const totalExpectedGaps = results.filter((r) => r.expectedGap && !r.matched).length;
const totalMissed = results.filter((r) => !r.matched && !r.expectedGap).length;
console.log(`Overall: ${totalSurfaced}/20 surfaced, ${totalMissed} unexpected misses, ${totalExpectedGaps} expected gaps.`);

const exitCode = totalMissed > 0 ? 1 : 0;
process.exit(exitCode);
