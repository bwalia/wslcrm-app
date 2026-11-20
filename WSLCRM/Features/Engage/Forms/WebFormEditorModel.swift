import SwiftUI

/// One form being edited (the web's form editor page). The draft — title, questions, "create records" —
/// saves itself shortly after each change, with the form's `updated_at`, so a change made elsewhere
/// meanwhile is refused (409) rather than overwritten. Publishing makes the draft the live version.
@MainActor
@Observable
final class WebFormEditorModel {
    enum SaveState: Equatable { case saved, dirty, saving, failed, conflict }

    let uuid: String
    private let api: WebFormsAPI
    private(set) var form: WebFormDetail?
    private(set) var loadError: APIError?
    var title = ""
    private(set) var fields: [WebFormField] = []
    private(set) var targets: [WebFormTarget] = []
    private(set) var targetOptions: [WebFormTargetOption] = []
    private(set) var saveState: SaveState = .saved
    var notice: EngageNotice?
    private(set) var publishing = false

    /// Edits not saved yet; edits made while a save is in flight are saved next.
    private var edits = 0
    private var updatedAt: String?
    private var debounce: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    init(uuid: String, api: WebFormsAPI) {
        self.uuid = uuid
        self.api = api
    }

    // MARK: Loading

    func load() async {
        do {
            async let options = try? api.targets()
            let loaded = try await api.form(uuid)
            adopt(loaded)
            targetOptions = await options ?? []
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    /// Takes the server's copy of everything (after a load, a publish, a reload).
    private func adopt(_ next: WebFormDetail) {
        form = next
        updatedAt = next.updatedAt
        title = next.title
        fields = Self.keepingIdentity(next.fields, from: fields)
        targets = next.targets
    }

    /// The server's fields, keeping each question's on-screen identity (an open question stays open).
    nonisolated static func keepingIdentity(_ next: [WebFormField], from old: [WebFormField]) -> [WebFormField] {
        var byKey: [String: UUID] = [:]
        for field in old { if let key = field.key { byKey[key] = field.id } }
        var used = Set<UUID>()
        return next.enumerated().map { index, field in
            var copy = field
            if let key = field.key, let id = byKey[key], !used.contains(id) {
                copy.id = id
            } else if old.indices.contains(index), !used.contains(old[index].id), old[index].type == field.type {
                copy.id = old[index].id
            }
            used.insert(copy.id)
            return copy
        }
    }

    func reload() async {
        debounce?.cancel()
        do {
            let fresh = try await api.form(uuid)
            edits = 0
            adopt(fresh)
            saveState = .saved
            notice = .info("Reloaded: this is the latest version.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    // MARK: Editing

    var publishedKeys: Set<String> { Set(form?.publishedKeys ?? []) }

    func field(_ id: UUID) -> WebFormField? { fields.first { $0.id == id } }
    func index(of id: UUID) -> Int? { fields.firstIndex { $0.id == id } }

    /// Changes one question. A key follows its label until the form is published (then answers depend on it),
    /// and rules below that refer to it follow too.
    func update(_ id: UUID, _ change: (inout WebFormField) -> Void) {
        guard let index = index(of: id) else { return }
        var field = fields[index]
        let oldLabel = field.label
        change(&field)
        if field.label != oldLabel, !field.isLocked, let oldKey = field.key, !publishedKeys.contains(oldKey),
           field.label.trimmedOrNil != nil {
            let taken = Set(fields.enumerated().filter { $0.offset != index }.compactMap(\.element.key))
            let newKey = WebFormRules.key(fromLabel: field.label, taken: taken)
            field.key = newKey
            fields[index] = field
            WebFormRules.renameKey(oldKey, to: newKey, in: &fields)
        } else {
            fields[index] = field
        }
        touch()
    }

    /// Adds a question at the end (or after `after`) and returns its id.
    @discardableResult
    func add(_ type: WebFormFieldType, after: UUID? = nil) -> UUID {
        let field = WebFormRules.newField(type, taken: Set(fields.compactMap(\.key)))
        if let after, let index = index(of: after) { fields.insert(field, at: index + 1) } else { fields.append(field) }
        touch()
        return field.id
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let index = index(of: id) else { return nil }
        var copy = fields[index]
        copy.id = UUID()
        copy.system = nil
        copy.label = "\(copy.label) (copy)"
        copy.key = WebFormRules.key(fromLabel: copy.label, taken: Set(fields.compactMap(\.key)))
        fields.insert(copy, at: index + 1)
        touch()
        return copy.id
    }

    /// Deletes a question (a locked one stays: "create records" needs it).
    func remove(_ id: UUID) {
        guard let index = index(of: id), !fields[index].isLocked else { return }
        fields.remove(at: index)
        touch()
    }

    func move(from source: IndexSet, to destination: Int) {
        fields.move(fromOffsets: source, toOffset: destination)
        touch()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = index(of: id) else { return }
        let target = index + offset
        guard fields.indices.contains(target) else { return }
        fields.swapAt(index, target)
        touch()
    }

    func setTitle(_ text: String) {
        title = text
        touch()
    }

    /// Turns a "create records" target on or off (an invitation starts with the member role when there is one).
    func setTarget(_ key: String, on: Bool) {
        if on {
            guard !targets.contains(where: { $0.type == key }) else { return }
            var target = WebFormTarget(type: key)
            if key == "user", let roles = targetOptions.first(where: { $0.key == "user" })?.roles {
                target.role = roles.first { $0.name == "member" }?.name ?? roles.first?.name
            }
            targets.append(target)
        } else {
            targets.removeAll { $0.type == key }
        }
        touch()
    }

    func setInviteRole(_ role: String) {
        targets = targets.map { $0.type == "user" ? WebFormTarget(type: "user", role: role) : $0 }
        touch()
    }

    /// Why a locked question is locked, in words.
    var lockReason: String? {
        let names = targets.compactMap { target in targetOptions.first { $0.key == target.type }?.label.lowercased() }
        guard !names.isEmpty else { return nil }
        return "This form needs it to \(names.joined(separator: " and ")). Turn that off under “Create records” to unlock it."
    }

    // MARK: Saving

    private func touch() {
        edits += 1
        saveState = .dirty
        schedule()
    }

    private func schedule() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Saves now (before publishing, when leaving the screen).
    func flush() async {
        debounce?.cancel()
        if let inFlight { await inFlight.value }
        guard edits > 0, saveState != .conflict, form != nil else { return }
        let seen = edits
        saveState = .saving
        let body = WebFormsAPI.draftBody(title: title, fields: fields, targets: targets, expectedUpdatedAt: updatedAt)
        let task = Task { [weak self, api, uuid] in
            do {
                let next = try await api.update(uuid, body: body)
                self?.saved(next, seen: seen)
            } catch {
                self?.saveFailed(error.asAPIError)
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func saved(_ next: WebFormDetail, seen: Int) {
        updatedAt = next.updatedAt
        form = next
        if edits == seen {
            // Nothing changed meanwhile: take the server's version (it may have added or locked the contact
            // questions the targets need).
            edits = 0
            fields = Self.keepingIdentity(next.fields, from: fields)
            targets = next.targets
            saveState = .saved
        } else {
            edits -= seen
            saveState = .dirty
            schedule()
        }
    }

    private func saveFailed(_ error: APIError) {
        if error.serverError?.status == 409 {
            saveState = .conflict
            notice = .info("Someone changed this form somewhere else. Reload it to see their version.")
        } else {
            saveState = .failed
            notice = .failed(error)
        }
    }

    // MARK: Actions

    var canPublish: Bool {
        guard let form, saveState != .conflict else { return false }
        return form.publishedVersion == nil || form.hasUnpublishedChanges || saveState != .saved
    }

    var publishTitle: String {
        guard let form else { return "Publish" }
        if form.publishedVersion == nil { return "Publish" }
        return canPublish ? "Publish changes" : "Published"
    }

    /// Returns true when it was the first publish (the share tab is next).
    @discardableResult
    func publish() async -> Bool {
        publishing = true
        defer { publishing = false }
        await flush()
        guard saveState == .saved || saveState == .dirty else { return false }
        do {
            let next = try await api.publish(uuid)
            edits = 0
            adopt(next)
            saveState = .saved
            let first = next.publishedVersion == 1
            notice = .done(first ? "Published — your form is live." : "Changes published.")
            return first
        } catch {
            notice = .failed(error.asAPIError)
            return false
        }
    }

    func setOpen(_ open: Bool) async {
        do {
            let next = try await api.setOpen(uuid, open: open)
            form = next
            updatedAt = next.updatedAt
            notice = .done(open ? "Reopened: it takes responses again." : "Closed — it no longer takes responses.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    /// Saves the settings tab; throws so the tab can show the problem by its setting.
    func saveSettings(_ settings: WebFormSettings) async throws {
        await flush()
        let next = try await api.update(uuid, body: WebFormsAPI.settingsBody(settings, expectedUpdatedAt: updatedAt))
        form = next
        updatedAt = next.updatedAt
    }

    func duplicate() async -> WebFormDetail? {
        do {
            let copy = try await api.duplicate(uuid)
            notice = .done("Copied as a new draft: “\(copy.title)”.")
            return copy
        } catch {
            notice = .failed(error.asAPIError)
            return nil
        }
    }

    func delete() async -> Bool {
        do {
            try await api.delete(uuid)
            return true
        } catch {
            notice = .failed(error.asAPIError)
            return false
        }
    }
}
