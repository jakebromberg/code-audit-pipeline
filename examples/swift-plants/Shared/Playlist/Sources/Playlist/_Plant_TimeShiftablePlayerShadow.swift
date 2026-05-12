//
//  _Plant_TimeShiftablePlayerShadow.swift
//  Playlist
//
//  PLANT 08: same NAME as Playback:TimeShiftablePlayer (protocol), different shape.
//

import Foundation

protocol TimeShiftablePlayer {
    var canShiftBackward: Bool { get }
    var maxShiftAmount: TimeInterval { get }
    func shift(by seconds: TimeInterval) async
}
