// origin-package.mjs
//
// Bare-specifier resolver for `kind: "import"` rows in the type-catalog
// (see docs/pipeline-contract.md §"Import rows" and the design brief at
// docs/plans/118-B-imports-kind.md §2 "origin_package resolution algorithm").
//
// Tier 1 / v1: text-only. Strip subpath off bare specifiers to recover the
// published-package name; flag relative and absolute paths as `null`. Tier 2
// (tsconfig `paths` aliases, `package.json` `name` walking) is intentionally
// deferred — the bare-specifier rule catches ≥95% of cross-repo consumer
// edges in well-behaved npm codebases and requires zero filesystem reads.

export function resolveOriginPackage(specifier) {
  if (specifier.startsWith('.') || specifier.startsWith('/')) {
    return { origin_package: null, origin_resolution: 'relative' };
  }
  const parts = specifier.split('/');
  const pkg = specifier.startsWith('@') && parts.length >= 2
    ? `${parts[0]}/${parts[1]}`
    : parts[0];
  return { origin_package: pkg, origin_resolution: 'bare-specifier' };
}
