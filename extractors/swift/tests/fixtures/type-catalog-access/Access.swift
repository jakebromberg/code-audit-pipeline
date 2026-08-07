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
}
