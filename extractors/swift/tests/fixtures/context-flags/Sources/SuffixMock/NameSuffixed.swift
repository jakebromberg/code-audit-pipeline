// Fixture for V7 §6.6 — name-suffix `is_mock` signal. The protocol's name
// ends with `Mock`, but the file lives in Sources/SuffixMock/ (NOT under
// a Mocks/Stubs/Fakes directory). Tests that the per-record name-suffix
// check fires independently of the path-based one.
protocol AccountServiceMock {
    var session: String { get }
}

// Mirror with `Stub` suffix.
protocol PaymentStub {
    var amount: Int { get }
}

// Mirror with `Fake` suffix.
protocol AnalyticsFake {
    var event: String { get }
}

// V7 §6.6 function-record assertions: methods on Mock-suffixed types vs free
// functions in the same file. The containing-type segment is what the
// FunctionCatalogVisitor checks for is_mock, not the function name itself.
// Methods on FooMock should fire is_mock; free functions should not.
struct FooMock {
    // 3+ body lines so `--min-body-lines` default doesn't filter them out.
    func executeQuery() -> Int {
        let x = 1
        let y = 2
        return x + y
    }

    func resetState() {
        let counter = 0
        let total = counter + 1
        _ = total
    }
}

// Free function in the same file — no containing type. Should fire NEITHER
// is_mock from path (file isn't in Mocks/) NOR is_mock from name suffix
// (the function name doesn't carry the suffix; the containing-type check
// requires a containing type).
func freeHelperFunction() -> String {
    let a = "alpha"
    let b = "beta"
    return a + b
}

// A struct WITHOUT a Mock suffix — methods on it should NOT fire is_mock,
// even though they sit in the same file as `FooMock`. Confirms the check is
// per-record, not per-file.
struct RegularProvider {
    func providerWork() -> Int {
        let one = 1
        let two = 2
        return one + two
    }
}
