// Basename contains the substring ".test." but does NOT end with
// ".test.swift" — it ends with ".helpers.swift". `isTestPath`'s suffix-only
// basename rule does not match this file, so `is_test` is correctly false
// in the type/func catalogs. But the pre-#317 `literal` filter matched
// `.test.` anywhere in the basename, so this file was excluded from
// literal-catalog.json before this PR; `isLiteralExcludedPath` keeps that
// legacy substring rule so `literal` still excludes it (a strict superset
// of the pre-#317 exclusion set), even though it is not a "test path" by
// the contract's normative definition.
struct LegacySubstringHelper {
    static let legacySubstringValue = 42
}

func legacySubstringHelperFn() -> Int {
    return 1 + 1
}
