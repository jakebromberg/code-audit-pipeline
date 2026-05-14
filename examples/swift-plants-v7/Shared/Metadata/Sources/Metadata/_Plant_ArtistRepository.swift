//
//  _Plant_ArtistRepository.swift
//  Metadata
//
//  Persistence contract for resolved Discogs artist entities.
//
//  Created by Jake Bromberg on 03/04/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct Artist: Sendable, Codable {
    public let id: Int
    public let name: String
}

/// Repository contract for fetching and persisting resolved Artist entities.
public protocol ArtistRepository: Sendable {
    func resolve(id: Int) async throws -> Artist
    func list() async throws -> [Artist]
    func cacheKey(for id: Int) -> String
    var lastSync: Date? { get }
}
