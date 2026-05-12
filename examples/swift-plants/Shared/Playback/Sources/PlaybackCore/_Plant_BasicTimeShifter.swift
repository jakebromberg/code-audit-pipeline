//
//  _Plant_BasicTimeShifter.swift
//  Playback
//
//  PLANT 12: protocol with 3 members subset of Playback:TimeShiftablePlayer's 6.
//

import Foundation

protocol BasicTimeShifter {
    var isAtLiveEdge: Bool { get }
    var secondsBehindLive: TimeInterval { get }
    func seekToLive() async
}
