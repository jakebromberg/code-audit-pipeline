// Fixture for V7 §6.6 — `is_mock` from path. File lives under a `Mocks/`
// directory; the record's name doesn't carry a mock suffix. Tests that the
// path-based check fires independently of the name-suffix check. Also
// validates `is_test: true` co-occurs (the file is under Tests/), since the
// flags are emitted independently and downstream consumers want to see both.
struct AuthClient {
    var token: String
}
