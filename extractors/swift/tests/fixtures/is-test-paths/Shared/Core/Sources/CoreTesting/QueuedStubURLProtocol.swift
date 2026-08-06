// A testing-support library target — NOT a test target. `CoreTesting` is
// not an exact match for the `test`/`tests` directory-segment rule, so
// is_test must be false. This is the case the contract's exact-match
// requirement guards against.
struct QueuedStubURLProtocol {
    var name: String
}

func queuedStubURLProtocolHelper() -> Int {
    let value = 1
    let other = 2
    let sum = value + other
    return sum
}
