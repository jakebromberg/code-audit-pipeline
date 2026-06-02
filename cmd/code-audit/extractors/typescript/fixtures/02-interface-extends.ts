// Fixture: interface with multiple extends; the supertypes themselves are
// declared above so they appear in the same catalog.
// Expected: Child.extends = ["Parent", "Sibling"] (sorted alpha).

export interface Parent {
  id: number;
}

export interface Sibling {
  meta: string;
}

export interface Child extends Parent, Sibling {
  extra: boolean;
}
