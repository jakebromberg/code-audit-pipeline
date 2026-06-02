// One resolvable dynamic import + one unresolvable template-literal form
// (extractor must skip the latter — the spec text is not statically known).

export async function loadTarget() {
  const mod = await import('./target');
  return mod;
}

export async function loadDynamic(name: string) {
  const mod = await import(`./${name}`);
  return mod;
}
