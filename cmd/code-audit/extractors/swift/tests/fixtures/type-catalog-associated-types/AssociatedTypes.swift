// AssociatedTypes.swift — fixtures exercising `TypeRecord.associated_types`
// (issue #320, shape and emission rule settled in #321's joint decision).
//
// Covers:
//   1. PrimaryOnly<Element> — a primary associated type. Swift requires it
//      to also be declared as an `associatedtype` member, so this exercises
//      the "appears in both positions" case: one entry, `primary: true`.
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
