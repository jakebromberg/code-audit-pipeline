//
//  _Plant_ShowContainer.swift
//  PlaybackCore
//
//  View-model contract for the now-playing show surface.
//
//  Created by Jake Bromberg on 03/01/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct Show: Sendable, Equatable {
    public let id: UInt64
    public let title: String
}

/// Contract for a view-model that owns a single Show + supports refresh.
public protocol ShowContainerProtocol: Sendable {
    var item: Show { get }
    var pageToken: String? { get }
    var lastRefreshedAt: Date? { get }
    var isStale: Bool { get }
}
