// Fixture: type-alias-object referencing another named type.
// Expected: Holder.references = [{name: "Inner", kind: "type-ref"}].

export interface Inner {
  value: number;
}

export type Holder = {
  data: Inner;
};
