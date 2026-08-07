// Basename ends in `.fixture.swift` (universal filename pattern). Literal-
// catalog-inert; exercises the `.fixture.swift` suffix rule in
// `isTestPath`.
struct SuffixFixtureCase {
    var value: Int
}

func suffixFixtureCaseHelper() -> Int {
    return 1 + 1
}
