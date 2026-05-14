//
//  _Plant_GenericFetcher.swift
//  Caching
//
//  Single-shot remote fetch helpers for primitive payload types.
//
//  Created by Jake Bromberg on 03/12/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public enum GenericFetcher {
    public static func fetchInt(from url: URL) async throws -> Int {
        let request = URLRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(Int.self, from: data)
    }

    public static func fetchString(from url: URL) async throws -> String {
        let request = URLRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(String.self, from: data)
    }
}
