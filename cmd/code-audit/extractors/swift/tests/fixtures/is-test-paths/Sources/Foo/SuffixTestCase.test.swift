// Basename ends in `.test.swift` (universal filename pattern). Literal-
// catalog-inert; exercises the `.test.swift` suffix rule in `isTestPath`.
struct SuffixTestCase {
    var value: Int
}

func suffixTestCaseHelper() -> Int {
    return 1 + 1
}
