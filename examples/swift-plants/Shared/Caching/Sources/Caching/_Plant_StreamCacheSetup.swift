//
//  _Plant_StreamCacheSetup.swift
//  Caching
//
//  PLANT 02: mirrors Playback:MP3StreamerConfiguration (4 fields) under a
//  different name in a different package.
//

import Foundation

struct StreamCacheSetup {
    let bufferQueueSize: Int
    let connectionTimeout: TimeInterval
    let minimumBuffersBeforePlayback: Int
    let url: URL
}
