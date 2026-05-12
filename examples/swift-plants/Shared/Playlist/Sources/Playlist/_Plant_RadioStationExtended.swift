//
//  _Plant_RadioStationExtended.swift
//  Playlist
//
//  PLANT 16: near-duplicate of Core:RadioStation (Jaccard 0.86). 6 original
//  fields + 1 new (licenseId).
//

import Foundation

struct RadioStationExtended {
    let description: String
    let hlsStreamURL: URL
    let merchURL: URL
    let name: String
    let requestLine: URL
    let streamURL: URL
    let licenseId: String
}
