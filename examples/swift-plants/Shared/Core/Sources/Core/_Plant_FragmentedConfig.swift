//
//  _Plant_FragmentedConfig.swift
//  Core
//
//  PLANT 20: extension-fragmented type. Base declaration has 1 field; two
//  extensions in sibling files each add 1 more (y, z). Sibling
//  _Plant_UnifiedConfig.swift declares a struct with all three fields. Without
//  extension-merging in swift-catalog, subset-pairs.jq cannot relate them.
//

import Foundation

struct FragmentedConfig {
    let x: Int
}
