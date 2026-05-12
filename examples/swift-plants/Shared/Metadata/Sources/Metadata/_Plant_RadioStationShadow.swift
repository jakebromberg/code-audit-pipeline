//
//  _Plant_RadioStationShadow.swift
//  Metadata
//
//  PLANT 05: same NAME as Core:RadioStation, different shape. Surfaces in
//  cross-package-shadows-any.jq but NOT exact-duplicates (shapes differ).
//

import Foundation

struct RadioStation {
    let id: UUID
    let callSign: String
    let frequency: Double
}
