// Fixture: mapped type `{[K in keyof T]: string}`. K is scoped (mapped key
// parameter); T is scoped (outer type parameter); `string` is primitive.
// Expected: Stringified.references = [].

export type Stringified<T> = { [K in keyof T]: string };
