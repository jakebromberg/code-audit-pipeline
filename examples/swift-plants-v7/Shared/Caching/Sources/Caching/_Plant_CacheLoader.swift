//
//  _Plant_CacheLoader.swift
//  Caching
//
//  Async loader contract for cached blobs.
//
//  Created by Jake Bromberg on 03/08/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Loader contract that fetches a cached payload by key.
public protocol CacheLoader: Sendable {
    var cacheKey: String { get }
    var lastLoadedAt: Date? { get }
    func load() async throws -> Data
    func invalidate() async
}
