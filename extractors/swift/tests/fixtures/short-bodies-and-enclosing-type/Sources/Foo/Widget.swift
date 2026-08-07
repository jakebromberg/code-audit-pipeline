// Fixture for issue #318 — short-body rows + enclosing_type.

struct Concert {}

func donate(_ concerts: [Concert]) async throws {}

func oneLiner() -> Int { 1 }

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
