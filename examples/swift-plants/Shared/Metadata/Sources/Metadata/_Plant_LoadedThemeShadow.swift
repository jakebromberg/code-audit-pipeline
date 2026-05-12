//
//  _Plant_LoadedThemeShadow.swift
//  Metadata
//
//  PLANT 07: same NAME as Wallpaper:LoadedTheme, different shape.
//

import Foundation

struct LoadedTheme {
    let themeId: String
    let lastModified: Date
    let cacheKey: String
    let bundle: Bundle?
    let metadata: [String: Any]
}
