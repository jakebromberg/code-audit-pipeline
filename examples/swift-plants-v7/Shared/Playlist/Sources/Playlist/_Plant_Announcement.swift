//
//  _Plant_Announcement.swift
//  Playlist
//
//  Announcement entries (PSAs, station IDs) interleaved into the rotation feed.
//
//  Created by Jake Bromberg on 02/22/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public struct Announcement: PlaylistEntry {
    public let id: UInt64
    public let hour: UInt64
    public let chronOrderID: UInt64
    public let timeCreated: UInt64

    public init(id: UInt64, hour: UInt64, chronOrderID: UInt64, timeCreated: UInt64) {
        self.id = id
        self.hour = hour
        self.chronOrderID = chronOrderID
        self.timeCreated = timeCreated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UInt64.self, forKey: .id)
        self.hour = try container.decode(UInt64.self, forKey: .hour)
        self.chronOrderID = try container.decode(UInt64.self, forKey: .chronOrderID)
        self.timeCreated = try container.decodeIfPresent(UInt64.self, forKey: .timeCreated) ?? container.decode(UInt64.self, forKey: .hour)
    }

    private enum CodingKeys: String, CodingKey {
        case id, hour, chronOrderID, timeCreated
    }
}
