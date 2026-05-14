//
//  _Plant_StringCache.swift
//  Caching
//
//  In-memory cache keyed by String identifiers.
//
//  Created by Jake Bromberg on 03/15/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct StringCache: Sendable {
    private var storage: [String: CacheEntry] = [:]
    public var capacity: Int
    public var lastAccess: Date?
    public var hitCount: UInt64

    public init(capacity: Int = 256) {
        self.capacity = capacity
        self.hitCount = 0
    }
}
