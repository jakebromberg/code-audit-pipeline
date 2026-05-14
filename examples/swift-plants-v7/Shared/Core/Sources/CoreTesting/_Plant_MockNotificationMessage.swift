//
//  _Plant_MockNotificationMessage.swift
//  CoreTesting
//
//  Test-only NotificationMessage variant used to verify the observation pipeline
//  without touching the production MainActor/Async parent surface.
//
//  Created by Jake Bromberg on 02/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Core

/// Mock notification message used by tests to inject synthesized notifications
/// into observers without going through MainActorNotificationMessage's
/// thread-affinity constraints. Mirrors the parent protocol shape so call
/// sites observing the real message can be exercised against this mock.
public protocol MockNotificationMessage: Sendable {
    /// The type of object that can be the subject of this message.
    associatedtype Subject

    /// The notification name used for posting and observing this message type.
    nonisolated static var name: Notification.Name { get }

    /// Converts a traditional `Notification` to this message type.
    /// Returns `nil` if the notification cannot be converted.
    static func makeMessage(_ notification: sending Notification) -> Self?

    /// Converts this message to a traditional `Notification`.
    static func makeNotification(_ message: Self, object: Subject?) -> Notification
}
