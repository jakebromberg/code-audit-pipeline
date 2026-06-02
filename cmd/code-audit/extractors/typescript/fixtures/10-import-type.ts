// Fixture: `import("./other").Remote` should produce a reference to Remote
// (the qualifier, not the module specifier).
// Expected: RemoteHolder.references = [{name: "Remote", kind: "type-ref"}].

export type RemoteHolder = import('./other').Remote;
