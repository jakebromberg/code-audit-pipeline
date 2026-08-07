// Access.swift — fixtures exercising `TypeRecord.access` (issue #319).
//
// Covers all three `TypeRecord(` construction sites so each emits the
// modifier as written, defaulting to "internal" when none is present:
//
//   1. emitShapeBearing (struct / class / actor / protocol / extension)
//   2. emitEnum (enum — kind "type-alias-union")
//   3. the typealias visitor (kind "type-alias-other")

public final class PublicClass {}

open class OpenClass {}

package struct PackageStruct {
    let value: Int
}

internal struct ExplicitInternalStruct {
    let value: Int
}

struct ImplicitInternalStruct {
    let value: Int
}

fileprivate struct FileprivateStruct {
    let value: Int
}

private struct PrivateStruct {
    let value: Int
}

public actor PublicActor {}

actor ImplicitInternalActor {}

public protocol PublicProto {
    func a()
}

protocol ImplicitInternalProto {
    func a()
}

public enum PublicEnum {
    case a
    case b
}

private enum PrivateEnum {
    case x
}

enum ImplicitInternalEnum {
    case y
}

public typealias PublicAlias = Int

private typealias PrivateAlias = Double

typealias ImplicitInternalAlias = String

public struct ExtensionTarget {}

public extension ExtensionTarget {
    func extended() {}

    // Pins the written-syntax caveat. Swift makes this type genuinely public
    // across module boundaries — a declaration inside an extension defaults to
    // the extension's access level, not to `internal`. No modifier is written
    // here, so `access` reports "internal" while `exported` resolves true.
    // That divergence is deliberate; see docs/pipeline-contract.md
    // "access (type vs literal)". Asserted below so it cannot drift silently.
    struct NestedInPublicExtension {}
}

// Modifier ordering: `access` must pick the access modifier, not the first
// modifier in the list.
public final class PublicFirstFinal {}

final public class FinalFirstPublic {}
