//
//  _Plant_MetadataLoader.swift
//  Metadata
//
//  Async loader contract for resolved playcut metadata.
//
//  Created by Jake Bromberg on 03/08/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Loader contract that fetches a resolved metadata payload by key.
public protocol MetadataLoader: Sendable {
    var cacheKey: String { get }
    var lastLoadedAt: Date? { get }
    func load() async throws -> PlaycutMetadata
    func invalidate() async
}
