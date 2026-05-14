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
