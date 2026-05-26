// Fixture: self-recursive interface. Per the plan §7 decision, the self-name
// IS emitted as a reference — matches what a graph-view consumer expects
// (a self-loop is a real edge).
// Expected: TreeNode.references = [{name: "TreeNode", kind: "type-ref"}].

export interface TreeNode {
  value: number;
  children?: TreeNode[];
}
