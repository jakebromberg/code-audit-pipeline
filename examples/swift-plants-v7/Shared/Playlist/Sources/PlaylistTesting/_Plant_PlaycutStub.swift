//
//  _Plant_PlaycutStub.swift
//  PlaylistTesting
//
//  Convenience constructor for Playcut test fixtures.
//
//  Created by Jake Bromberg on 02/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Playlist

extension Playcut {
    /// Creates a Playcut with sensible defaults for testing.
    public static func stub(
        id: UInt64 = 1,
        hour: UInt64 = 1000,
        chronOrderID: UInt64? = nil,
        timeCreated: UInt64? = nil
    ) -> Playcut {
        Playcut(
            id: id,
            hour: hour,
            chronOrderID: chronOrderID ?? id,
            timeCreated: timeCreated ?? hour
        )
    }
}
