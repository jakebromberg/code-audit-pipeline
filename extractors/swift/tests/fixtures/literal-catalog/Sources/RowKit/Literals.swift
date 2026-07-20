//
//  Literals.swift — fixture for test_literal_catalog.sh
//
//  Exercises the two emitted literal positions (binding initializer, call
//  argument) plus the positions v1 deliberately does NOT emit (enum raw
//  values, return statements, tuple elements, string literals). Values are
//  chosen to be unique per case so assertions can select by value.
//  This file is parsed, never compiled — SwiftUI-ish code is fine.
//

import SwiftUI

private struct ArtworkStyle {
    static let cornerRadius: CGFloat = 6.0
}

struct SongRowContent {
    private let placeholderCornerRadius = 6.0
    var insets = 12

    var body: some View {
        VStack {
            RoundedRectangle(cornerRadius: 12)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .opacity(0.50)
        .offset(x: -4)
    }

    func pad() {
        let localSpacing = 8
        _ = localSpacing
    }
}

extension SongRowContent {
    static let extensionPad = 20
}

enum PlaybackCode: Int {
    case stopped = 99
}

struct Oddballs {
    let big = 1_000
    let mask = 0xFF
    let scientific = 1e3
    let tuple = (7001, 7002)
    let text = "6"

    func answer() -> Int {
        return 424_242
    }
}
