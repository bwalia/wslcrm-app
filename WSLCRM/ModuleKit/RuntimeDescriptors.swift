import Foundation
import os

/// Descriptors built while the app runs, from a description the server sends (a plugin's generated
/// page, `GET /api/v2/plugins/:code/resources/:key`). Registering one lets the kit's shared screens
/// open its records by id (`ResourceRoute`), exactly like the descriptors compiled into the app.
enum RuntimeDescriptors {
    private static let table = OSAllocatedUnfairLock(initialState: [String: ResourceDescriptor]())

    /// Adds or replaces a descriptor (the server's description may change: rights, fields).
    static func register(_ descriptor: ResourceDescriptor) {
        table.withLock { $0[descriptor.id] = descriptor }
    }

    static func descriptor(_ id: String) -> ResourceDescriptor? {
        table.withLock { $0[id] }
    }
}
