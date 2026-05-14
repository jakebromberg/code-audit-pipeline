//
//  _Plant_ReleaseRepository.swift
//  Metadata
//
//  Persistence contract for resolved Discogs release entities.
//
//  Created by Jake Bromberg on 03/04/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct Release: Sendable, Codable {
    public let id: Int
    public let name: String
}

/// Repository contract for fetching and persisting resolved Release entities.
public protocol ReleaseRepository: Sendable {
    var entityKind: String { get }
    var lastSync: Date? { get }
    func cacheKey(for id: Int) -> String
    func resolve(id: Int) async throws -> Release
}
