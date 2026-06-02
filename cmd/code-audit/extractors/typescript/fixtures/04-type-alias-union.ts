// Fixture: union type — variants go into `references`, NOT `extends`.
// Spec §6.3: treating union variants as inheritance would over-claim.
// Expected: Result.extends = []
//           Result.references = [{name: "Err", kind: "type-ref"}, {name: "Ok", kind: "type-ref"}]
//           Result.kind = "type-alias-union"

export interface Ok {
  value: string;
}

export interface Err {
  message: string;
}

export type Result = Ok | Err;
