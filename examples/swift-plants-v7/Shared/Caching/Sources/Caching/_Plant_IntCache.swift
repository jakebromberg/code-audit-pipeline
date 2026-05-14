//
//  _Plant_IntCache.swift
//  Caching
//
//  In-memory cache keyed by Int identifiers.
//
//  Created by Jake Bromberg on 03/15/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct IntCache: Sendable {
    private var storage: [Int: CacheEntry] = [:]
    public var capacity: Int
    public var lastAccess: Date?
    public var hitCount: UInt64

    public init(capacity: Int = 256) {
        self.capacity = capacity
        self.hitCount = 0
    }
}

public struct CacheEntry: Sendable {
    public let data: Data
    public let expiresAt: Date
}
