// Fixture: tuple, array, readonly array — each element type's reference surfaces.
// Expected: Triple.references = [A, B, C] sorted.

export interface A { aa: number; }
export interface B { bb: number; }
export interface C { cc: number; }

export type Triple = [A, B[], readonly C[]];
