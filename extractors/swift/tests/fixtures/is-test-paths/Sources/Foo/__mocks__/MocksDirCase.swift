// Directory segment "__mocks__" (universal pattern). Literal-catalog-inert;
// exercises the "__mocks__" directory-segment rule in `isTestPath`.
struct MocksDirCase {
    var value: Int
}

func mocksDirCaseHelper() -> Int {
    return 1 + 1
}
