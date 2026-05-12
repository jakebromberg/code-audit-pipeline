//
//  _Plant_BroadcastSource.swift
//  Metadata
//
//  PLANT 01: mirrors Core:RadioStation (6 fields) under a different name in a
//  different package. Surfaces in exact-duplicates.jq via matching shape_sig.
//

import Foundation

struct BroadcastSource {
    let description: String
    let hlsStreamURL: URL
    let merchURL: URL
    let name: String
    let requestLine: URL
    let streamURL: URL
}
