//
//  StickyState.swift
//  Face ID for Mac (by PK)
//
//  The only state that must survive a restart: a sticky pause (wrong stored password). Attempt counts deliberately
//  do NOT persist — a launch while locked is quiet anyway (UnlockPolicy.launched).
//

import Foundation

nonisolated struct StickyState: Codable, Equatable, Sendable {
    var stickyPause: PauseReason?

    static func load(from url: URL) -> StickyState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(StickyState.self, from: data) else { return StickyState() }
        return state
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
