// Fixture for §6.4 acceptance: two functions identical except for type
// identifier substitutions should produce identical body_hash_erased while
// their existing body_hash values differ.
//
// Box1.makeArray and Box2.makeArray differ only at the IdentifierTypeSyntax
// for UIColor vs NSColor. After type-erasure (replace IdentifierTypeSyntax
// names with _T1, _T2, ... in order of first appearance), both bodies erase
// to the same normalized form.
//
// Probe1.swap exists to verify multi-distinct-types erasure: Foo and Bar
// each get their own placeholder (_T1, _T2). The corresponding partner is
// Probe2.swap below, which uses Baz and Quux in the same slots.

struct Box1 {
    let value: UIColor

    func makeArray() -> [UIColor] {
        let copy: UIColor = value
        let pair: [UIColor] = [copy, value]
        return pair
    }
}

struct Box2 {
    let value: NSColor

    func makeArray() -> [NSColor] {
        let copy: NSColor = value
        let pair: [NSColor] = [copy, value]
        return pair
    }
}

struct Probe1 {
    func swap(_ x: Foo, _ y: Bar) -> (Bar, Foo) {
        let a: Bar = y
        let b: Foo = x
        return (a, b)
    }
}

struct Probe2 {
    func swap(_ x: Baz, _ y: Quux) -> (Quux, Baz) {
        let a: Quux = y
        let b: Baz = x
        return (a, b)
    }
}
