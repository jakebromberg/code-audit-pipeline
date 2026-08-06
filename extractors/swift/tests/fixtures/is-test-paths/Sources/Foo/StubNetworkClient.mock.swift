// Basename ends in `.mock.swift` — the universal filename-pattern rule
// matches regardless of directory (Sources/Foo has no test-directory
// segment).
struct StubNetworkClient {
    var name: String
}

func stubNetworkClientHelper() -> Int {
    let value = 7
    let other = 8
    let sum = value + other
    return sum
}
