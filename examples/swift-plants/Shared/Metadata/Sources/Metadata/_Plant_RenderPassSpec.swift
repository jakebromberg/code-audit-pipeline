//
//  _Plant_RenderPassSpec.swift
//  Metadata
//
//  PLANT 19: shape-identical to Wallpaper:PassConfiguration (5 fields, Jaccard
//  1.0) but a different name in a different package. Surfaces in
//  cross-package-shape-near-duplicates-any.jq (and also exact-duplicates by shape).
//

import Foundation

struct RenderPassSpec {
    let effectiveScale: Float
    let fragmentFunction: String
    let inputs: [PassInput]?
    let name: String
    let scale: Float?
}
