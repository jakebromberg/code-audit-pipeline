// Heritage.swift — fixtures exercising the extends/conforms_to split.
//
// Cases covered (asserted in test_type_catalog_heritage.sh):
//
//   1. class FooClass: BaseClass, ProtoA {}
//      Default-both: BaseClass and ProtoA are neither in the curated
//      class-only nor protocol-only sets, so both land in BOTH
//      `extends` and `conforms_to`. Cluster queries disambiguate by
//      joining against the target's `kind`.
//
//   2. class BarObjC: NSObject, Identifiable {}
//      Curated split: NSObject → extends only; Identifiable → conforms_to only.
//      (Identifiable rather than Equatable because NSObject already provides
//      Equatable via NSObjectProtocol — SourceKit flags the redundancy. The
//      curated-split test only cares that NSObject lands in extends and the
//      protocol lands in conforms_to; either marker exercises the partition.)
//
//   3. struct BazStruct: Sendable, Hashable {}
//      Structs cannot class-inherit, so the curated stdlib protocols
//      both go to conforms_to; extends stays empty.
//
//   4. protocol Pproto: Qproto, Rproto {}
//      Protocol declarations: every inherited identifier is a protocol
//      (Swift forbids protocols inheriting from concrete types), so the
//      whole list goes to conforms_to, extends is empty.
//
//   5. extension BazStruct: Codable {}
//      Extensions record their extended type in `extends` (the extension
//      IS-A extension-of BazStruct) AND record the explicit conformance
//      (Codable) in `conforms_to`. Codable is a stdlib protocol marker.
//
//   6. struct NotifMsg: SomeNotificationMessage {
//          static var name: Notification.Name { AVPlayer.rateDidChangeNotification }
//      }
//      Wrapper detection: conforms to a *NotificationMessage protocol AND
//      declares static var name: Notification.Name → wraps_notification_name
//      records "AVPlayer.rateDidChangeNotification".

import Foundation

class BaseClass {}

protocol ProtoA {
    func a() -> Int
}

class FooClass: BaseClass, ProtoA {
    func a() -> Int { 0 }
}

class BarObjC: NSObject, Identifiable {
    let id: Int = 0
}

struct BazStruct: Sendable, Hashable {
    let value: Int
}

protocol Qproto {
    var x: Int { get }
}

protocol Rproto {
    func r()
}

protocol Pproto: Qproto, Rproto {}

extension BazStruct: Codable {}

protocol SomeNotificationMessage {
    static var name: Notification.Name { get }
}

struct NotifMsg: SomeNotificationMessage {
    static var name: Notification.Name { AVPlayer.rateDidChangeNotification }
}

// Negative case: a struct that does NOT conform to *NotificationMessage and
// does not declare `static var name: Notification.Name`. The extractor must
// not carry wraps_notification_name on a row whose conforms_to set doesn't
// match the wrapper protocol pattern AND whose body lacks the requirement.
// (Originally this case conformed to SomeNotificationMessage to also exercise
// the "conforms but no name" branch, but SourceKit flagged the missing
// protocol requirement — the negative case is equivalent without the
// conformance, and the extractor's heritage + name-detection logic is each
// covered independently by other cases.)
struct NoNameMsg {
    let unrelated: Int
}

// Negative case for the conformance gate (issue #222): an Identifiable-like
// model that exposes `static var name: Notification.Name` for its own reasons
// (e.g., owns a notification namespace) but DOES NOT conform to a
// *NotificationMessage protocol. The extractor must NOT tag this as a
// notification wrapper — without the conformance gate, this would falsely
// surface in `notification-wrapper-grouping.jq` and cluster with real
// notification messages that happen to share a Notification.Name value.
struct ModelOwningANotificationName {
    let identifier: String
    static var name: Notification.Name { Notification.Name("model.unrelated") }
}

// Positive case for the iOS 26 Foundation protocols (issue #222):
// `NotificationCenter.MainActorMessage` (and `NotificationCenter.AsyncMessage`)
// are the canonical wrapper protocols Apple ships with iOS 26 — the
// pipeline-contract.md detection rule explicitly lists them alongside the
// project-naming `*NotificationMessage` suffix. The qualified identifier
// `NotificationCenter.MainActorMessage` does NOT end in "NotificationMessage"
// (it ends in "MainActorMessage"), so a suffix-only gate would silently miss
// it. The detection in TypeCatalogVisitor must explicitly OR-in the qualified
// Foundation names. This fixture locks that behavior in.
//
// Placeholder so the conformance type parses cleanly without importing
// Foundation; only the qualified identifier text matters for detection.
enum NotificationCenter {
    protocol MainActorMessage {}
    protocol AsyncMessage {}
}
struct PlayerRateDidChangeMessage: NotificationCenter.MainActorMessage {
    static var name: Notification.Name { AVPlayer.rateDidChangeNotification }
}
struct PlayerStateAsyncMessage: NotificationCenter.AsyncMessage {
    static var name: Notification.Name { Notification.Name("player.state") }
}

// Placeholder so AVPlayer.rateDidChangeNotification references resolve
// at parse time for the fixture (we don't import AVFoundation here).
enum AVPlayer {
    static let rateDidChangeNotification = Notification.Name("AVPlayerItemDidPlayToEndTime")
}
