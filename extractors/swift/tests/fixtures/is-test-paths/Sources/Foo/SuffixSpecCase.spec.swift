// Basename ends in `.spec.swift` (universal filename pattern). Literal-
// catalog-inert; exercises the `.spec.swift` suffix rule in `isTestPath`.
struct SuffixSpecCase {
    var value: Int
}

func suffixSpecCaseHelper() -> Int {
    return 1 + 1
}
