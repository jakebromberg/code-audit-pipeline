// Directory segment "tests" (lowercase, universal pattern). No literal
// bindings — this fixture is literal-catalog-inert; it exists solely to
// exercise the "tests" directory-segment rule in `isTestPath`.
struct LowerTestsDirCase {
    var value: Int
}

func lowerTestsDirCaseHelper() -> Int {
    return 1 + 1
}
