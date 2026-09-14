import CryptoKit
import Foundation

/// File cache of raw API responses, used so engineers can open their visits, jobs and
/// phases without signal. Raw bytes are cached (not re-encoded models), so cached data is
/// decoded by exactly the same code path as live data.
actor ResponseCache {
    struct Entry: Sendable {
        let data: Data
        let savedAt: Date
    }

    private let directory: URL

    init(directory: URL = ResponseCache.defaultDirectory()) {
        self.directory = directory
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
            // Cache writes are best effort.
        }
    }

    func load(key: String, namespaceId: String) -> Entry? {
        let url = fileURL(key: key, namespaceId: namespaceId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Entry(data: data, savedAt: modified ?? .distantPast)
    }

    func remove(key: String, namespaceId: String) {
        try? FileManager.default.removeItem(at: fileURL(key: key, namespaceId: namespaceId))
    }

    /// Removes all cached responses (sign-out).
    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(key: String, namespaceId: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let safeNamespace = namespaceId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory
            .appendingPathComponent(safeNamespace.isEmpty ? "_" : safeNamespace, isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }
}
