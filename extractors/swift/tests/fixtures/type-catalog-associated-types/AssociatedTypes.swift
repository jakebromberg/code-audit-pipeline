// AssociatedTypes.swift — fixtures exercising `TypeRecord.associated_types`
// (issue #320, shape and emission rule settled in #321's joint decision).
//
// Covers:
//   1. PrimaryOnly<Element> — a primary associated type that is ALSO declared
//      as an `associatedtype` member: one entry, `primary: true`.
//   2. PlainMember — an `associatedtype` member with no primary clause →
//      `primary: false`.
//   3. Constrained — an `associatedtype` with an inheritance clause →
//      `constraints` populated, sorted.
//   4. Empty — a protocol declaring no associated types → `associated_types`
//      present as `[]`, not absent.
//   5. NotAProtocol — a struct, to assert `associated_types` is OMITTED
//      entirely (has("associated_types") is false).

protocol PrimaryOnly<Element> {
    associatedtype Element
}

protocol PlainMember {
    associatedtype Value
}

protocol Constrained {
    associatedtype Item: Hashable, Codable
}

protocol Empty {
    func doThing()
}

struct NotAProtocol {
    let value: Int
}

// 6. An INHERITED primary associated type. `Child` names `Element` in its
//    primary clause but declares no `associatedtype` member — `Element` comes
//    from `Parent`. This is valid Swift (`any Child<Int>` works), so `Child`
//    must report one entry with `primary: true`, not an empty array. Its
//    `constraints` are empty because the bound lives on `Parent`, which this
//    row does not walk.
protocol Parent {
    associatedtype Element: Equatable
}

protocol Child<Element>: Parent {}

// 7. Multiple associated types, declared out of alphabetical order, so the
//    documented sort-by-name is actually exercised. With only single-entry
//    protocols the sort could be deleted outright and every assertion would
//    still pass.
protocol SortOrder {
    associatedtype Zed
    associatedtype Alpha
}

// 8. A protocol-composition bound. Must normalize to the same array as the
//    comma form below, or `constraints | index("Sendable")` misses this
//    spelling.
protocol CompositionBound {
    associatedtype Composed: Codable & Sendable
}

protocol CommaBound {
    associatedtype Listed: Codable, Sendable
}
