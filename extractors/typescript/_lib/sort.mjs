// sort.mjs
//
// Tiny multi-key comparator factory. Replaces hand-rolled
//   if (a.k1 !== b.k1) return a.k1 < b.k1 ? -1 : 1;
//   if (a.k2 !== b.k2) return a.k2 < b.k2 ? -1 : 1;
//   ...
// chains across extractor sort sites with one declarative call:
//   rows.sort(compareBy((r) => r.k1, (r) => r.k2, ...));

export const compareBy = (...keyFns) => (a, b) => {
  for (const k of keyFns) {
    const av = k(a);
    const bv = k(b);
    if (av !== bv) return av < bv ? -1 : 1;
  }
  return 0;
};
