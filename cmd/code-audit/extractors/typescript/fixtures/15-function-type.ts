// Fixture: function type with parameter and return refs.
// Expected: Transform.references = [Input, Output] sorted.

export interface Input { i: number; }
export interface Output { o: number; }

export type Transform = (x: Input) => Output;
