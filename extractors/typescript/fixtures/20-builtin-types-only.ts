// Fixture: declaration whose body references ONLY deny-listed built-ins.
// Verifies the deny-list is comprehensive — none of these should surface.
// Expected: OnlyBuiltins.references = []

export type OnlyBuiltins = {
  fetched: Promise<string>;
  list: Array<number>;
  meta: Map<string, Date>;
  optional: Partial<Record<string, boolean>>;
  err: Error;
};
