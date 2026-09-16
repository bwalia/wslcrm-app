import CryptoKit
import Foundation
import os

/// File cache of raw API responses, used so engineers can open their visits, jobs and
/// phases without signal. Raw bytes are cached (not re-encoded models), so cached data is
/// decoded by exactly the same code path as live data.
/// The cache is bounded: an engineer who works hundreds of jobs a year must not end up with a
/// cache that grows for the life of the install. Entries older than `maxAge` are dropped, and
/// the oldest are evicted once the total passes `maxBytes`.
actor ResponseCache {
    struct Entry: Sendable {
        let data: Data
        let savedAt: Date
    }

    struct Limits: Sendable {
        var maxBytes = 64 * 1024 * 1024
        var maxAge: TimeInterval = 30 * 24 * 60 * 60
        /// Sweep at most this often; every write would be wasteful.
        var sweepInterval: TimeInterval = 5 * 60
    }

    private let directory: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    private var lastSweep: Date?
    private let log = Logger(subsystem: "uk.co.workstation.wslcrm", category: "cache")

    init(directory: URL = ResponseCache.defaultDirectory(), limits: Limits = Limits(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.now = now
    }

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ResponseCache", isDirectory: true)
    }

    func store(_ data: Data, key: String, namespaceId: String) {
        let url = fileURL(key: key, namespaceId: namespaceId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Best effort, but a failing cache is worth knowing about when a device fills up.
            log.error("Cache write failed: \(String(describing: error), privacy: .public)")
        }
        sweepIfNeeded()
    }

    func load(key: String, namespaceId: String) -> Entry? {
        let url = fileURL(key: key, namespaceId: namespaceId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let savedAt = modified ?? .distantPast
        guard now().timeIntervalSince(savedAt) <= limits.maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Entry(data: data, savedAt: savedAt)
    }

    func remove(key: String, namespaceId: String) {
        try? FileManager.default.removeItem(at: fileURL(key: key, namespaceId: namespaceId))
    }

    /// Removes all cached responses (sign-out).
    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Drops expired entries, then the oldest ones until the cache fits in `maxBytes`.
    @discardableResult
    func sweep() -> (removed: Int, bytes: Int) {
        lastSweep = now()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        var files: [(url: URL, modified: Date, size: Int)] = []
        var removed = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            if now().timeIntervalSince(modified) > limits.maxAge {
                try? FileManager.default.removeItem(at: url)
                removed += 1
                continue
            }
            files.append((url, modified, values.fileSize ?? 0))
        }
        var total = files.reduce(0) { $0 + $1.size }
        if total > limits.maxBytes {
            for file in files.sorted(by: { $0.modified < $1.modified }) where total > limits.maxBytes {
                try? FileManager.default.removeItem(at: file.url)
                total -= file.size
                removed += 1
            }
        }
        if removed > 0 { log.info("Cache sweep removed \(removed) file(s); \(total) bytes left") }
        return (removed, total)
    }

    private func sweepIfNeeded() {
        guard let lastSweep else { return sweep_() }
        guard now().timeIntervalSince(lastSweep) > limits.sweepInterval else { return }
        sweep_()
    }

    private func sweep_() { _ = sweep() }

    private func fileURL(key: String, namespaceId: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let safeNamespace = namespaceId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory
            .appendingPathComponent(safeNamespace.isEmpty ? "_" : safeNamespace, isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }
}
