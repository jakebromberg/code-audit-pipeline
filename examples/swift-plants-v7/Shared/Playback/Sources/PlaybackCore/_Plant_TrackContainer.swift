//
//  _Plant_TrackContainer.swift
//  PlaybackCore
//
//  View-model contract for the now-playing track surface.
//
//  Created by Jake Bromberg on 03/01/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct Track: Sendable, Equatable {
    public let id: UInt64
    public let title: String
}

/// Contract for a view-model that owns a single Track + supports refresh.
public protocol TrackContainerProtocol: Sendable {
    var item: Track { get }
    var pageToken: String? { get }
    var lastRefreshedAt: Date? { get }
    var isStale: Bool { get }
}
