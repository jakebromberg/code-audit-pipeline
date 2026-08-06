// Under Shared/Playlist/Tests/... — the `Tests` directory segment matches.
struct CapturingURLProtocol {
    var name: String
}

func capturingURLProtocolHelper() -> Int {
    let value = 3
    let other = 4
    let sum = value + other
    return sum
}
