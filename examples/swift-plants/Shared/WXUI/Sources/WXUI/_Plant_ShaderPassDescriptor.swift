//
//  _Plant_ShaderPassDescriptor.swift
//  WXUI
//
//  PLANT 03: mirrors Wallpaper:PassConfiguration (5 fields) under a different
//  name in a different package.
//

import Foundation

struct ShaderPassDescriptor {
    let effectiveScale: Float
    let fragmentFunction: String
    let inputs: [PassInput]?
    let name: String
    let scale: Float?
}
