//
//  _Plant_GraphicsConfiguration.swift
//  WXUI
//
//  PLANT 14: near-duplicate of Wallpaper:ComputeConfiguration (Jaccard 0.8).
//

import Foundation

struct GraphicsConfiguration {
    let particleCount: Int?
    let passes: [ComputePassConfiguration]
    let persistentTextures: [PersistentTextureConfiguration]?
    let renderFunction: String
    let antialiasLevel: Int
}
