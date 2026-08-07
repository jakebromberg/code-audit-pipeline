// Top-level canonical-SwiftPM test target: Tests/FooTests/... . Before the
// `resolvePackage` fix, this and Tests/BarTests/... both fell through to
// the `parts.first ?? "root"` default and collapsed to the single
// synthetic package "Tests" — indistinguishable from each other and from
// no package at all. The fix adds a `Tests/<X>/...` arm symmetric with
// `Sources/<X>/...`, so this resolves to package "FooTests". Literal-
// catalog-inert (no literal bindings).
struct FooTestsCase {
    var value: Int
}

func fooTestsCaseHelper() -> Int {
    return 1 + 1
}
