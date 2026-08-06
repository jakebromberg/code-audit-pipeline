// `FooTesting` is a shipped testing-support library target, not a test
// target — same shape as Shared/Core/Sources/CoreTesting above, at the
// SwiftPM Sources/<Pkg> layout instead of the Shared/<Pkg> layout.
struct FooTestingSupport {
    var name: String
}

func fooTestingSupportHelper() -> Int {
    let value = 9
    let other = 10
    let sum = value + other
    return sum
}
