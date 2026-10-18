//
//  EventLog.swift
//  Face ID for Mac (by PK)
//
//  A small, local, secret-free journal: what triggered, what the scan concluded, why something was refused, how long
//  it took. Never the password, never a camera frame. ~/Library/Logs/FaceIDforMac/events.jsonl, rotated at 1 MB × 3.
//  The last entries are shown in the settings window.
//

import Foundation
import Observation

@Observable
@MainActor
final class EventLog {
    static let shared = EventLog()

    struct Entry: Identifiable, Codable {
        var id = UUID()
        var at: Date
        var event: String
        var detail: String
    }

    private(set) var recent: [Entry] = []

    private let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FaceIDforMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("events.jsonl")
    }()

    func add(_ event: String, _ detail: String = "") {
        let entry = Entry(at: Date(), event: event, detail: detail)
        recent.insert(entry, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
        append(entry)
    }

    private func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        // The folder can disappear under us (cleanup tools) — recreate it, or the journal silently stops (seen 18.10).
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: fileURL)
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 1_000_000 else { return }
        let base = fileURL.deletingPathExtension().path
        try? fm.removeItem(atPath: base + ".3.jsonl")
        try? fm.moveItem(atPath: base + ".2.jsonl", toPath: base + ".3.jsonl")
        try? fm.moveItem(atPath: base + ".1.jsonl", toPath: base + ".2.jsonl")
        try? fm.moveItem(atPath: fileURL.path, toPath: base + ".1.jsonl")
    }
}
