// Fixture for issue #318 — short-body rows + enclosing_type.

struct Concert {}

func donate(_ concerts: [Concert]) async throws {}

func oneLiner() -> Int { 1 }

// Threshold-boundary cases (default --min-body-lines 3): exactly one below
// and exactly one above.
func twoLiner() -> Int {
    let a = 1
    return a
}

func fourLiner() -> Int {
    let a = 1
    let b = 2
    let c = 3
    return a + b + c
}

struct Widget {
    func noop() {}

    func longBody() -> Int {
        let a = 1
        let b = 2
        return a + b
    }

    var value: Int {
        1
    }
}

struct Outer {
    struct Inner {
        func method() {}
    }
}

extension Array<Concert> {
    func helper() {}
}

// Declaration kinds not previously covered: initializer, deinitializer,
// subscript, class member.
class Gadget {
    var count: Int = 0

    init(count: Int) {
        self.count = count
    }

    deinit {
        count = 0
    }

    func poke() {}

    subscript(index: Int) -> Int {
        count + index
    }
}

// actor member
actor Counter {
    func bump() {}
}

// enum member
enum Direction {
    func opposite() -> Direction {
        self
    }
}

// protocol default implementation
protocol Greeter {
    func greet() -> String
}

extension Greeter {
    func greet() -> String {
        "hello"
    }
}
