// Basename ends in `.fixtures.swift` (universal filename pattern). Literal-
// catalog-inert; exercises the `.fixtures.swift` suffix rule in
// `isTestPath`.
struct SuffixFixturesCase {
    var value: Int
}

func suffixFixturesCaseHelper() -> Int {
    return 1 + 1
}
