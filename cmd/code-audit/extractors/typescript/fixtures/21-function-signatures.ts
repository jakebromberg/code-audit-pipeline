// Fixture 21: function-catalog signature extraction.
//
// Used by function-catalog.test.mjs to validate typed-param / return-ref /
// generics-binding-filter / overload-head / arrow-via-const handling.

// Primitives only — no refs to extract. True one-liner so body fields gate to null.
export function noLeakPrimitives(s: string, n: number): boolean { return n > 0; }

// Typed param + typed return — both should produce type_refs.
type InternalRequest = { id: string };
export type PublicResponse = { ok: boolean };
export function leakyHandler(req: InternalRequest): PublicResponse {
  const tag = req.id.length > 0 ? 'present' : 'empty';
  const status = tag === 'present';
  return { ok: status };
}

// Arrow function via `export const` with generics — T must be filtered from refs.
export const boxArrow = <T>(value: T): { wrapped: T } => ({ wrapped: value });

// Non-exported helper.
function privateHelper(x: number): number {
  const doubled = x * 2;
  const tripled = x * 3;
  return doubled + tripled;
}

// Generics in both param and return — every ref should be filtered out.
export function identity<T>(value: T): T {
  return value;
}

// Overloaded — 2 heads + 1 impl. Each emits its own row.
export function overloaded(x: string): string;
export function overloaded(x: number): number;
export function overloaded(x: string | number): string | number {
  const tag = typeof x === 'string' ? 'str' : 'num';
  const stamp = `${tag}:${String(x)}`;
  return stamp;
}
