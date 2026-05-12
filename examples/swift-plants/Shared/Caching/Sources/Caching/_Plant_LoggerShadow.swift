//
//  _Plant_LoggerShadow.swift
//  Caching
//
//  PLANT 06: same NAME as Logger:Logger, different shape.
//

import Foundation

struct Logger {
    let identifier: String
    let cacheDirectory: URL
    let maxLogSize: Int
    let rotationCount: Int
}
