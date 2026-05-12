//
//  _Plant_StreamUtilities.swift
//  PLANT 18
//
//  PLANT 18 (Core copy): byte-identical to Playback/PlaybackCore copy. Surfaces
//  in file-duplicates.jq (exact sha256 cluster).
//

import Foundation

struct StreamMetrics {
    let bytesReceived: Int
    let bytesProcessed: Int
    let droppedFrames: Int
}

enum StreamReadiness {
    case idle
    case buffering
    case streaming(StreamMetrics)
    case error(String)
}

func averageBitrate(metrics: [StreamMetrics], elapsedSeconds: Double) -> Double? {
    guard elapsedSeconds > 0, !metrics.isEmpty else { return nil }
    let totalBits = metrics.reduce(0) { $0 + $1.bytesReceived * 8 }
    return Double(totalBits) / elapsedSeconds
}
