//
//  _Plant_EnhancedStreamerConfiguration.swift
//  Caching
//
//  PLANT 13: near-duplicate of Playback:MP3StreamerConfiguration (Jaccard 0.8).
//  Original 4 fields + 1 new (bufferStrategy).
//

import Foundation

struct EnhancedStreamerConfiguration {
    let bufferQueueSize: Int
    let connectionTimeout: TimeInterval
    let minimumBuffersBeforePlayback: Int
    let url: URL
    let bufferStrategy: String
}
