// Fixture: `typeof X` should produce a reference to X.
// Expected: TableShape.references = [{name: "userTable", kind: "type-ref"}].

export const userTable = { name: 'users', columns: ['id'] };

export type TableShape = typeof userTable;
