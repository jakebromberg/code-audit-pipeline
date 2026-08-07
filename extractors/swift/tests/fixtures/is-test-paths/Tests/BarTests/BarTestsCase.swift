// Sibling of Tests/FooTests/FooTestsCase.swift under a DIFFERENT top-level
// SwiftPM test target: Tests/BarTests/... . Before the `resolvePackage`
// fix, this collapsed to the same synthetic package "Tests" as
// Tests/FooTests/..., making the two indistinguishable to package-grouping
// queries (a false positive in name-collisions.jq, a false negative in
// cross-package-shadows-any.jq). With the fix this resolves to package
// "BarTests" — distinct from "FooTests". Literal-catalog-inert (no literal
// bindings).
struct BarTestsCase {
    var value: Int
}

func barTestsCaseHelper() -> Int {
    return 1 + 1
}
