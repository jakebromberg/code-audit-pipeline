//
//  _Plant_AppContextSettings.swift
//  Analytics
//
//  PLANT 04: mirrors AppServices:AppConfig (4 fields) under a different name
//  in a different package.
//

import Foundation

struct AppContextSettings {
    let apiBaseUrl: String
    let posthogApiKey: String
    let posthogHost: String
    let requestOMaticUrl: String
}
