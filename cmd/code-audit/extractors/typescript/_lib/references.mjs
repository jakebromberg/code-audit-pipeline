// references.mjs
//
// Shared reference-extraction primitives for TypeScript extractors. Both
// type-catalog and function-catalog walk type-position AST nodes to collect
// the user-defined type identifiers they reference; this module is the single
// implementation those callers import.
//
// Exports:
//   BUILTIN_TYPE_DENYLIST       Set of names treated as built-ins/utility
//                               types; they do not contribute references but
//                               their type arguments are walked.
//   getLeftmostIdentifierText   Pull the leftmost identifier text out of a
//                               QualifiedName chain (Namespace.Inner.Type ->
//                               Namespace).
//   extractReferences           Recursive walker; scope-threaded for generics
//                               binding filter. Output goes into a Set.
//   pushNamedRef                Helper used by the three named-ref node kinds
//                               (TypeReference, TypeQuery, ImportType).
//   refsForDecl                 Collect references for a declaration node:
//                               walks type-param constraints and each body
//                               node, returns sorted-deduped
//                               [{name, kind: "type-ref"}].
//   genericsList                Comma-joined type-parameter names, or null.

import ts from 'typescript';

export const BUILTIN_TYPE_DENYLIST = new Set([
  // Generic utility types
  'Pick', 'Omit', 'Partial', 'Required', 'Readonly', 'Record', 'NonNullable',
  'Awaited', 'Parameters', 'ReturnType', 'ConstructorParameters', 'InstanceType',
  'ThisParameterType', 'OmitThisParameter', 'Uppercase', 'Lowercase',
  'Capitalize', 'Uncapitalize', 'NoInfer', 'Exclude', 'Extract',
  // Drizzle infer helpers -- first-class on `infer_ref`, so treating them as
  // plain references would duplicate the structured signal noisily.
  'InferSelectModel', 'InferInsertModel',
  // Containers
  'Array', 'ReadonlyArray', 'Map', 'ReadonlyMap', 'Set', 'ReadonlySet',
  'WeakMap', 'WeakSet',
  // Async / iteration
  'Promise', 'PromiseLike', 'Iterable', 'Iterator', 'AsyncIterable',
  'AsyncIterator', 'Generator', 'AsyncGenerator', 'IterableIterator',
  // Built-in objects
  'Date', 'RegExp', 'Error', 'URL', 'URLSearchParams', 'Blob', 'ArrayBuffer',
  'Uint8Array', 'Int8Array', 'Uint16Array', 'Int16Array', 'Uint32Array',
  'Int32Array', 'Float32Array', 'Float64Array', 'BigInt64Array',
  'BigUint64Array', 'Uint8ClampedArray', 'DataView', 'SharedArrayBuffer',
  // Primitive wrappers
  'Object', 'String', 'Number', 'Boolean', 'Symbol', 'BigInt', 'Function',
]);

export function genericsList(node) {
  return node.typeParameters?.map((p) => p.name.text).join(',') ?? null;
}

// Leftmost identifier extraction for QualifiedName chains. Mirrors the
// resolution rule the downstream (package, name) lookup uses -- the leftmost
// distinguishes namespaces, not the deepest segment.
export function getLeftmostIdentifierText(typeName) {
  if (typeName.kind === ts.SyntaxKind.Identifier) return typeName.text;
  if (typeName.kind === ts.SyntaxKind.QualifiedName) return getLeftmostIdentifierText(typeName.left);
  return typeName.getText ? typeName.getText() : null;
}

// Recursive walker. Adds user-defined references to `sink`, threading `scope`
// (a Set of in-scope type-parameter names) so generics like
// `interface Foo<T> { x: T }` don't emit T as a reference. Function and
// mapped types introduce new scopes -- the new scope is a child Set union,
// never a mutation of the parent.
export function extractReferences(typeNode, sf, scope, sink) {
  if (!typeNode) return;

  // TypeReference / TypeQuery / ImportType all share the same shape: pull a
  // leftmost-identifier out of a name node, filter, recurse type arguments.
  if (ts.isTypeReferenceNode(typeNode))  return pushNamedRef(typeNode.typeName,  typeNode, sf, scope, sink);
  if (ts.isTypeQueryNode(typeNode))      return pushNamedRef(typeNode.exprName,  typeNode, sf, scope, sink);
  if (ts.isImportTypeNode(typeNode))     return pushNamedRef(typeNode.qualifier, typeNode, sf, scope, sink);

  if (ts.isFunctionTypeNode(typeNode) || ts.isConstructorTypeNode(typeNode)) {
    const child = new Set(scope);
    if (typeNode.typeParameters) {
      for (const tp of typeNode.typeParameters) child.add(tp.name.text);
      for (const tp of typeNode.typeParameters) {
        if (tp.constraint) extractReferences(tp.constraint, sf, child, sink);
      }
    }
    typeNode.parameters?.forEach((p) => { if (p.type) extractReferences(p.type, sf, child, sink); });
    if (typeNode.type) extractReferences(typeNode.type, sf, child, sink);
    return;
  }

  if (ts.isMappedTypeNode(typeNode) && typeNode.typeParameter) {
    const child = new Set(scope);
    child.add(typeNode.typeParameter.name.text);
    if (typeNode.typeParameter.constraint) {
      extractReferences(typeNode.typeParameter.constraint, sf, scope, sink);
    }
    // `as` rename clause (TS 4.1+): `{[K in keyof T as `prefix_${S & string}`]: ...}`.
    // S only appears in `nameType` -- without this recurse it would never surface.
    if (typeNode.nameType) extractReferences(typeNode.nameType, sf, child, sink);
    if (typeNode.type) extractReferences(typeNode.type, sf, child, sink);
    return;
  }

  ts.forEachChild(typeNode, (c) => extractReferences(c, sf, scope, sink));
}

export function pushNamedRef(nameNode, typeNode, sf, scope, sink) {
  if (nameNode) {
    const name = getLeftmostIdentifierText(nameNode);
    if (name && !scope.has(name) && !BUILTIN_TYPE_DENYLIST.has(name)) {
      sink.add(name);
    }
  }
  typeNode.typeArguments?.forEach((arg) => extractReferences(arg, sf, scope, sink));
}

// Collect references for a declaration. Walks each type-parameter constraint
// (`<T extends Item>` adds Item), then walks every body node with the
// declaration's type parameters in scope. Returns sorted-deduped
// {name, kind: "type-ref"}[].
export function refsForDecl(node, sf, bodyNodes) {
  const scope = new Set();
  const sink = new Set();
  if (node.typeParameters) {
    for (const tp of node.typeParameters) scope.add(tp.name.text);
    for (const tp of node.typeParameters) {
      if (tp.constraint) extractReferences(tp.constraint, sf, scope, sink);
    }
  }
  for (const n of bodyNodes) extractReferences(n, sf, scope, sink);
  return [...sink].sort().map((name) => ({ name, kind: 'type-ref' }));
}
