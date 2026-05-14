//
//  _Plant_AverageProcessor.swift
//  PlayerHeaderView
//
//  Sliding-window average processor for smoothed time-domain visualization
//
//  Created by Jake Bromberg on 02/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Accelerate
import Synchronization

/// Sliding-window average processor for smoothed time-domain visualization.
/// Note: @unchecked Sendable because it's primarily accessed from the single-threaded audio processing context.
/// The normalizer property is protected with Mutex for thread-safe access when normalization mode changes from MainActor.
final class AverageProcessor: @unchecked Sendable, AudioProcessor {
    private let normalizerMutex: Mutex<any Normalizer>
    private var rollingSum: [Float] = Array(repeating: 0, count: VisualizerConstants.barAmount)

    init(normalizationMode: NormalizationMode = .ema) {
        self.normalizerMutex = Mutex(normalizationMode.createNormalizer())
    }

    func process(data: UnsafeMutablePointer<Float>, frameLength: Int) -> [Float] {
        var averages = [Float](repeating: 0, count: VisualizerConstants.barAmount)
        let samplesPerBar = max(1, frameLength / VisualizerConstants.barAmount)

        for barIndex in 0..<VisualizerConstants.barAmount {
            let startIndex = barIndex * samplesPerBar
            let endIndex = min(startIndex + samplesPerBar, frameLength)
            let sampleCount = endIndex - startIndex

            guard sampleCount > 0 else { continue }

            var sum: Float = 0
            for i in startIndex..<endIndex {
                sum += abs(data[i])
            }

            let mean = sum / Float(sampleCount)
            averages[barIndex] = mean * VisualizerConstants.magnitudeLimit * 2
        }

        // Apply normalization (thread-safe access)
        normalizerMutex.withLock { normalizer in
            normalizer.normalize(&averages, outputScale: VisualizerConstants.magnitudeLimit)
        }

        return averages
    }

    func reset() {
        normalizerMutex.withLock { normalizer in
            normalizer.reset()
        }
    }

    func setNormalizationMode(_ mode: NormalizationMode) {
        normalizerMutex.withLock { normalizer in
            normalizer = mode.createNormalizer()
        }
    }
}
