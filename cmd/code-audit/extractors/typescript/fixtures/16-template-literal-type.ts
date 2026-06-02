// Fixture: template literal type. v1 walks children via the default
// fall-through; the embedded type reference surfaces.
// Expected: Greeting.references = [{name: "Name", kind: "type-ref"}].

export type Name = 'world' | 'friend';

export type Greeting = `hello ${Name}`;
