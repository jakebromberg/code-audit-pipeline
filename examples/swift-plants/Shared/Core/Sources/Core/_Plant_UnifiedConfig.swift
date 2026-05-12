//
//  _Plant_UnifiedConfig.swift
//  Core
//
//  PLANT 20: sibling struct holding all 3 fields. Compared to FragmentedConfig,
//  whose fields are spread across three records, it should cluster as a
//  subset-pair only after the extractor merges extensions into the base.
//

import Foundation

struct UnifiedConfig {
    let x: Int
    let y: String
    let z: Bool
}
