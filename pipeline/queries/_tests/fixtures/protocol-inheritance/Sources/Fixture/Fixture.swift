//
// Test fixture for V7 §6.3 protocol-inheritance resolution. Each protocol
// declared here exercises a specific path through `resolveProtocolInheritance`.
// Run `pipeline/queries/_tests/test_inheritance_resolution.sh` to verify the
// extractor produces the expected `resolved_from` / `inherited_from` shape
// on this fixture.
//

// Plain base protocol — no inheritance. Resolution pass leaves it alone.
protocol BaseAlpha {
    var alphaName: String { get }
    var alphaCount: Int { get }
}

// Single-step inheritance — basic union path. ChildBeta's resolved fields
// should be [alphaCount, alphaName, betaTag]. inherited_from = [BaseAlpha].
protocol ChildBeta: BaseAlpha {
    var betaTag: String { get }
}

// Transitive inheritance — fixed-point loop. GrandchildGamma pulls fields
// from ChildBeta directly AND from BaseAlpha transitively after a second
// iteration. inherited_from contains both.
protocol GrandchildGamma: ChildBeta {
    var gammaIndex: Int { get }
}

// External-protocol skip — Codable isn't in this fixture's scanned root, so
// it stays in conforms_to but never appears in inherited_from. resolved_from
// is NOT set (no in-catalog parent contributed anything).
protocol ExternallyConformedDelta: Codable {
    var deltaPayload: String { get }
}

// Field-collision child-wins — both BaseAlpha and CollidingEpsilon declare
// `alphaName: String`. The resolved record's fields contain exactly one
// `alphaName:String` entry, not two.
protocol CollidingEpsilon: BaseAlpha {
    var alphaName: String { get }
    var epsilonExtra: Int { get }
}

// Class-conformance skip — a class with a protocol parent in its
// inheritance clause doesn't trigger resolution; resolution is protocol-only.
// Class records carry conforms_to but resolved_from stays unset.
class ProtocolConformingZeta: BaseAlpha {
    var alphaName: String { return "" }
    var alphaCount: Int { return 0 }
    var zetaSpecific: Bool { return false }
}
