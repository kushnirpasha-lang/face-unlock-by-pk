//
//  FrameQualityGate.swift
//  Face ID for Mac (by PK)
//
//  Decides whether a camera frame is good enough to count toward recognition. Glance read pose and quality but never
//  used them for unlocking (G7). A skipped frame is simply not evaluated — it is never an unlock and never a failure.
//

import Foundation

nonisolated struct FrameFacts: Sendable {
    /// Faces whose width is at least the "this is a person at the Mac" share of the frame.
    var sizableFaceCount: Int
    /// All five alignment points (both eyes, nose, both mouth corners) were found for the chosen face.
    var hasFullLandmarks: Bool
    /// Radians, as Vision reports them. nil = unknown.
    var yaw: Float?
    var pitch: Float?
    /// Vision face-capture quality 0…1. nil = unknown.
    var quality: Float?
}

nonisolated enum FrameVerdict: Equatable, Sendable {
    case use
    case skip(FrameSkip)
    /// Someone else is right there too — refuse to unlock on this frame.
    case refuseMultipleFaces
}

nonisolated enum FrameSkip: String, Sendable {
    case noFace, partialFace, turnedAway, lowQuality
}

nonisolated enum FrameQualityGate {
    static let maxAngle: Float = 25 * .pi / 180
    static let qualityFloor: Float = 0.2

    static func evaluate(_ f: FrameFacts) -> FrameVerdict {
        guard f.sizableFaceCount > 0 else { return .skip(.noFace) }
        guard f.sizableFaceCount == 1 else { return .refuseMultipleFaces }
        guard f.hasFullLandmarks else { return .skip(.partialFace) }
        if let yaw = f.yaw, abs(yaw) > maxAngle { return .skip(.turnedAway) }
        if let pitch = f.pitch, abs(pitch) > maxAngle { return .skip(.turnedAway) }
        if let q = f.quality, q < qualityFloor { return .skip(.lowQuality) }
        return .use
    }
}
