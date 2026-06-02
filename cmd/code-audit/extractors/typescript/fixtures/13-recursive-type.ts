// Fixture: self-recursive interface. The self-name IS emitted as a reference
// — matches what a graph-view consumer expects (a self-loop is a real edge),
// per the contract's "self-references are emitted" rule.
// Expected: TreeNode.references = [{name: "TreeNode", kind: "type-ref"}].

export interface TreeNode {
  value: number;
  children?: TreeNode[];
}
