// Basename ends in `.mocks.swift` (universal filename pattern). Literal-
// catalog-inert; exercises the `.mocks.swift` suffix rule in `isTestPath`.
struct SuffixMocksCase {
    var value: Int
}

func suffixMocksCaseHelper() -> Int {
    return 1 + 1
}
