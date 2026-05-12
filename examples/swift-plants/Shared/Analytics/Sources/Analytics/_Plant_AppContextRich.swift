//
//  _Plant_AppContextRich.swift
//  Analytics
//
//  PLANT 15: near-duplicate of AppServices:AppConfig (Jaccard 0.8).
//

import Foundation

struct AppContextRich {
    let apiBaseUrl: String
    let posthogApiKey: String
    let posthogHost: String
    let requestOMaticUrl: String
    let environment: String
}
