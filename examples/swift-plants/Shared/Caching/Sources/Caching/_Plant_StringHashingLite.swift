//
//  _Plant_StringHashingLite.swift
//  Caching
//
//  PLANT 17 PLANT: hashSlugLite — same body as hashSlug except the hash
//  multiplier (1 line different out of 8). Targets Jaccard ~0.78.
//

import Foundation

enum SlugHasherLite {
    static func hashSlugLite(_ input: String) -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let bytes = Array(lowered.utf8)
        var hash = 5381
        for byte in bytes {
            hash = (hash * 33) &+ Int(byte)
        }
        return hash
    }
}
