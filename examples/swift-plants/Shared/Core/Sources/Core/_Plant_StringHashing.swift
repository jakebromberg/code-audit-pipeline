//
//  _Plant_StringHashing.swift
//  Core
//
//  PLANT 17 SOURCE: hashSlug — DJB2 string hash. Counterpart in Caching has 1
//  line different (variant hash multiplier), targeting Jaccard ~0.78 on body lines.
//

import Foundation

enum SlugHasher {
    static func hashSlug(_ input: String) -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let bytes = Array(lowered.utf8)
        var hash = 5381
        for byte in bytes {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return hash
    }
}
