// Fixture for V7 §6.6 — `is_mock` from path. File lives under a `Mocks/`
// directory; the record's name doesn't carry a mock suffix. Tests that the
// path-based check fires independently of the name-suffix check. Also
// validates `is_test: true` co-occurs (the file is under Tests/), since the
// flags are emitted independently and downstream consumers want to see both.
struct AuthClient {
    var token: String

    // Method on a non-Mock-suffixed type inside a Mocks/ path. Function-record
    // is_mock should fire from PATH (file is in Mocks/) regardless of the
    // containing-type name. Also is_test:true (file is under Tests/).
    func authenticate() -> Bool {
        let attempt = 1
        let allowed = attempt > 0
        return allowed
    }
}
