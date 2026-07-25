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
    // Emits now as a STRING binding (value_norm "6", value_kind "string"),
    // distinct from the numeric 6s above by value_kind.
    let text = "6"

    func answer() -> Int {
        return 424_242
    }
}

// --- String literals (v1 widening): binding position only ---

// Mirrored string constant across two unrelated types — the Slice A motivating
// case (wxyc-ios-64 #671): same value, containing names, different types.
struct FlagKeys {
    static let stationCapFlagKey = "on_tour_for_you_station_cap"

    // Escapes are NOT decoded: SwiftSyntax segment content is the raw source
    // text, so value_norm preserves the spelling — "a\tb" is the four characters
    // a \ t b, not a tab. Determinism is what the join key needs.
    let escaped = "a\tb"

    // NOT emitted: interpolated, multiline, and raw string literals.
    let interpolated = "prefix-\(stationCapFlagKey)"
    let multiline = """
        first
        second
        """
    let raw = #"not\ta\ttab"#

    func persist(_ store: UserDefaults) {
        // NOT emitted: string in ARGUMENT position (widening is binding-only),
        // even though the value mirrors the flag-key constants above.
        store.set(true, forKey: "on_tour_for_you_station_cap")
    }
}

struct FlagKeyMirror {
    static let onTourStationCapFlagKey = "on_tour_for_you_station_cap"
}
