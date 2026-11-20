import SwiftUI
import UIKit

/// Modal screens a campaign page can open (all presented from the page's List, never from a Section).
enum MktCampSheet: Identifiable {
    case schedule, reject, approval, duplicate, rename, gallery, editor, contactPicker
    case askAI(MktCampAskAIRequest)

    var id: String {
        switch self {
        case .schedule: "schedule"
        case .reject: "reject"
        case .approval: "approval"
        case .duplicate: "duplicate"
        case .rename: "rename"
        case .gallery: "gallery"
        case .editor: "editor"
        case .contactPicker: "contactPicker"
        case .askAI(let request): "ai:\(request.id)"
        }
    }
}

/// Questions a campaign page asks before acting.
enum MktCampConfirm: Identifiable {
    case send, cancel, delete, useDesign(MktDesign), easyEditor

    var id: String {
        switch self {
        case .send: "send"
        case .cancel: "cancel"
        case .delete: "delete"
        case .useDesign(let design): "design:\(design.name)"
        case .easyEditor: "easy"
        }
    }
}

/// Everything one campaign page holds: the campaign, the drafts of each tab (kept while switching
/// tabs), and the work behind every button.
@MainActor
@Observable
final class MktCampDetailModel {
    let api: MktCampAPI
    private(set) var uuid: String
    private(set) var campaign: MktCampaign?
    var loadError: APIError?
    var lists: [MktCampList] = []
    var listUUID = ""
    var tab: MktCampTab?
    var busy: String?
    var notice: EngageNotice?
    var validationWarnings: [String] = []
    var testMode = false
    var sheet: MktCampSheet?
    var confirm: MktCampConfirm?
    /// A copy was made: open it.
    var openedCopy: String?
    var deleted = false
    /// A list chosen where the person came from: saved on the email once it has loaded.
    var requestedList: String?
    private var draftsReady = false

    // Content
    var content = MktCampContent()
    private(set) var savedContent = MktCampContent()
    var mergeFields: [MktCampMergeField] = []
    var rendered: MktCampRendered?
    var previewError: APIError?
    var easyEditor = true
    var insertTarget = "body_html"
    var phoneWidthPreview = false
    var pickingImageFile = false
    var uploadingImage = false

    // Details
    var objective = ""
    var messageType = "marketing"
    var channel = "email"
    var approvalRequired = false

    // Audience
    var audiencePreview: MktCampAudiencePreview?
    private var audiencePreviewFor = ""
    var budget = ""
    var batchSize = ""
    var batchEvery = "60"
    var testEmail = ""
    var testResult: String?
    var eligibility: (name: String, allowed: Bool, text: String)?

    // Tracking
    var tracking = MktCampTracking()
    private(set) var savedTracking = MktCampTracking()
    var customGoal = false

    // A/B
    var ab = MktCampAB(enabled: false, variants: [])
    private(set) var savedAB = MktCampAB(enabled: false, variants: [])

    // Results
    var analytics: MktCampAnalytics?
    var analyticsError: APIError?
    var analyticsUpdated: Date?

    init(api: MktCampAPI, uuid: String, seed: MktCampaign?) {
        self.api = api
        self.uuid = uuid
        if let seed { apply(seed) }
    }

    // MARK: Derived

    var status: MktCampStatus { campaign?.status ?? .draft }
    var editable: Bool { status.isEditable }
    var activeTab: MktCampTab { tab ?? MktCampTab.initial(for: status) }
    var isBusy: Bool { busy != nil }
    var contentDirty: Bool { content != savedContent }
    var trackingDirty: Bool { tracking != savedTracking }
    var abDirty: Bool { ab != savedAB }
    var hasAudience: Bool { !listUUID.isEmpty || campaign?.listID != nil }
    var selectedList: MktCampList? { lists.first { $0.uuid == listUUID } }
    var detailsDirty: Bool {
        guard let campaign else { return false }
        return objective != campaign.objective || messageType != campaign.messageType || channel != campaign.channel
            || approvalRequired != campaign.approvalRequired
    }
    var budgetDirty: Bool { budget != (campaign?.maxDeliveries.map(String.init) ?? "") }
    var batchesDirty: Bool {
        batchSize != (campaign?.batchSize.map(String.init) ?? "")
            || (!batchSize.isEmpty && batchEvery != (campaign?.batchIntervalMinutes.map(String.init) ?? ""))
    }
    var nextStep: MktCampNextStep {
        MktCampNextStep.current(hasContent: campaign?.hasContent ?? false, hasAudience: hasAudience,
                                checked: status == .validated)
    }
    var pagePath: String { "/dashboard/opsapi-marketing/campaigns/\(uuid)" }

    // MARK: Loading

    func load() async {
        do {
            async let campaign = api.campaign(uuid)
            async let lists = try? api.lists()
            let loaded = try await campaign
            self.lists = await lists ?? []
            apply(loaded)
            if listUUID.isEmpty, let id = loaded.listID, let list = self.lists.first(where: { $0.id == id }) {
                listUUID = list.uuid
            }
            loadError = nil
            if let wanted = requestedList, loaded.status.isEditable,
               let list = self.lists.first(where: { $0.uuid == wanted }), list.id != loaded.listID {
                requestedList = nil
                await chooseList(list.uuid)
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    func loadExtras() async {
        if mergeFields.isEmpty { mergeFields = (try? await api.mergeFields()) ?? [] }
        testMode = (try? await api.sending())?.bool("dry_run") ?? false
    }

    /// Takes the server's copy of the campaign. The drafts are filled the first time only, so
    /// work in progress survives a refresh; the saved copies always follow the server.
    func apply(_ campaign: MktCampaign) {
        self.campaign = campaign
        savedContent = MktCampContent(campaign)
        savedTracking = MktCampTracking(campaign.record["tracking"])
        savedAB = campaign.ab
        guard !draftsReady else { return }
        draftsReady = true
        content = savedContent
        tracking = savedTracking
        customGoal = tracking.hasCustomGoal
        ab = savedAB
        easyEditor = !content.madeWithCode
        resetDetails()
        budget = campaign.maxDeliveries.map(String.init) ?? ""
        batchSize = campaign.batchSize.map(String.init) ?? ""
        batchEvery = campaign.batchIntervalMinutes.map(String.init) ?? "60"
    }

    func resetDetails() {
        guard let campaign else { return }
        objective = campaign.objective
        messageType = campaign.messageType
        channel = campaign.channel
        approvalRequired = campaign.approvalRequired
    }

    func reloadCampaign() async {
        if let fresh = try? await api.campaign(uuid) { apply(fresh) }
    }

    func loadAnalytics() async {
        do {
            analytics = try await api.analytics(uuid)
            analyticsError = nil
            analyticsUpdated = Date()
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            analyticsError = apiError
        }
    }

    // MARK: Running actions

    /// Runs one action, reloads the campaign, and says what happened.
    @discardableResult
    func run(_ label: String, done: String, _ work: () async throws -> Void) async -> Bool {
        busy = label
        notice = nil
        defer { busy = nil }
        do {
            try await work()
            await reloadCampaign()
            if status.isLive { await loadAnalytics() }
            notice = .done(done)
            return true
        } catch {
            notice = .failed(error.asAPIError)
            // It may have moved on (finished sending, say): show where it is now.
            await reloadCampaign()
            return false
        }
    }

    private var listBody: [String: JSONValue] { listUUID.isEmpty ? [:] : ["list_uuid": .string(listUUID)] }

    func check() async {
        await run("Check", done: "All good — it’s ready. Press “Send now”, or “Schedule” to pick a time.") {
            let answer = try await api.lifecycle(uuid, "validate", body: .object(listBody)).payload
            validationWarnings = (answer["warnings"]?.listValue ?? []).compactMap(\.stringValue)
            if let preview = MktCampAudiencePreview(answer["preview"]) {
                audiencePreview = preview
                audiencePreviewFor = listUUID
            }
        }
    }

    func sendNow() async {
        var body = listBody
        body["send_now"] = .bool(true)
        let ok = await run("Send", done: "Sending started. The results update every 15 seconds.") {
            try await api.lifecycle(uuid, "schedule", body: .object(body))
        }
        if ok { tab = .performance }
    }

    func schedule(at date: Date) async -> Bool {
        guard date > Date() else {
            notice = .info("That time has passed — choose a later one, or use Send now.")
            return false
        }
        var body = listBody
        body["scheduled_at"] = .string(APIDate.string(from: date))
        return await run("Schedule", done: "Scheduled for \(Formatters.dateTime(date) ?? "then").") {
            try await api.lifecycle(uuid, "schedule", body: .object(body))
        }
    }

    func approve() async {
        await run("Approve", done: "Approved — it’s ready to send.") { try await api.lifecycle(uuid, "approve") }
    }

    func reject(reason: String) async -> Bool {
        await run("Reject", done: "Sent back to draft with your reason.") {
            try await api.lifecycle(uuid, "reject", body: .object(["reason": .string(reason.trimmedOrNil ?? "Needs changes")]))
        }
    }

    func requestApproval(notes: String) async -> Bool {
        var body: [String: JSONValue] = [:]
        if let notes = notes.trimmedOrNil { body["notes"] = .string(notes) }
        return await run("Request approval", done: "Approval requested. Someone with approval rights can now approve it.") {
            try await api.lifecycle(uuid, "request-approval", body: .object(body))
        }
    }

    func pause() async {
        await run("Pause", done: "Paused. Messages not yet sent are held.") { try await api.lifecycle(uuid, "pause") }
    }

    func resume() async {
        await run("Resume", done: "Started again.") { try await api.lifecycle(uuid, "resume") }
    }

    func cancel() async {
        await run("Cancel", done: "Cancelled. Messages not yet sent were skipped.") { try await api.lifecycle(uuid, "cancel") }
    }

    func duplicate(name: String) async -> Bool {
        busy = "Copy"
        defer { busy = nil }
        do {
            let copy = try await api.duplicate(uuid, name: name)
            notice = .done("Copy made: “\(copy.name)”. It’s a draft, ready to change.")
            Task {
                // Open it once the "Make a copy" sheet has gone.
                try? await Task.sleep(for: .milliseconds(500))
                openedCopy = copy.uuid
            }
            return true
        } catch {
            notice = .failed(error.asAPIError)
            return false
        }
    }

    func delete() async {
        busy = "Delete"
        defer { busy = nil }
        do {
            try await api.delete(uuid)
            deleted = true
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    func rename(_ name: String) async -> Bool {
        guard let name = name.trimmedOrNil, name != campaign?.name else { return true }
        return await save(["name": .string(name)], done: "Renamed.")
    }

    /// `PUT` part of the campaign; says when it went back to draft (it must be checked again).
    @discardableResult
    func save(_ body: [String: JSONValue], done: String) async -> Bool {
        guard !body.isEmpty else { return true }
        busy = "Save"
        defer { busy = nil }
        let before = status
        do {
            let saved = try await api.update(uuid, body)
            apply(saved)
            notice = before != .draft && saved.status == .draft
                ? .info("\(done) It went back to draft — press “Check it” again before sending.")
                : .done(done)
            return true
        } catch {
            notice = .failed(error.asAPIError)
            return false
        }
    }

    // MARK: Content

    func saveContent() async {
        if await save(content.changes(since: savedContent), done: "Content saved.") { content = savedContent }
    }

    func saveDetails() async {
        guard let campaign else { return }
        var body: [String: JSONValue] = [:]
        if objective != campaign.objective { body["objective"] = .string(objective) }
        if messageType != campaign.messageType { body["message_type"] = .string(messageType) }
        if channel != campaign.channel { body["channel"] = .string(channel) }
        if approvalRequired != campaign.approvalRequired { body["approval_required"] = .bool(approvalRequired) }
        await save(body, done: "Details saved.")
    }

    func refreshPreview() async {
        guard let campaign else { return }
        do {
            rendered = try await api.preview(channel: campaign.channel, content: content)
            previewError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            previewError = apiError
        }
    }

    /// Puts a personalisation field (or any text) at the end of a field.
    func insert(_ token: String, into target: String) {
        switch target {
        case "subject": content.subject += token
        case "body_text": content.bodyText += token
        default: content.bodyHTML += token
        }
    }

    /// Copies a design's words and look into this email (it can still be changed afterwards).
    func use(_ design: MktDesign) {
        content.subject = design.subject.isEmpty ? content.subject : design.subject
        content.previewText = design.previewText.isEmpty ? content.previewText : design.previewText
        content.bodyHTML = design.bodyHTML
        content.bodyText = design.bodyText
        easyEditor = !content.madeWithCode
        notice = .info("Design “\(design.name)” is in. Change the words, then press Save content.")
    }

    func pickDesign(_ design: MktDesign) {
        if (content.bodyHTML + content.bodyText).trimmedOrNil != nil {
            confirm = .useDesign(design)
        } else {
            use(design)
        }
    }

    func uploadImage(_ file: EngageFile, client: EngageClient) async {
        uploadingImage = true
        defer { uploadingImage = false }
        do {
            guard let ready = MktCampImagePrep.forEmail(file) else {
                throw ResourceService.problem(422, "That picture couldn’t be read. Use a PNG, JPEG, GIF or WebP image.")
            }
            let src = try await MktEmailImages.upload(ready, using: client)
            content.bodyHTML += "\n<img src=\"\(src)\" alt=\"\" width=\"600\" style=\"max-width:100%;height:auto;display:block;border:0\" />"
            notice = .done("Picture added at the end of the email. Save content to keep it.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    // MARK: Audience

    /// Choosing who gets it saves straight away, so it's still chosen next time.
    func chooseList(_ uuid: String) async {
        listUUID = uuid
        guard !uuid.isEmpty else { return }
        do {
            apply(try await api.update(self.uuid, ["list_uuid": .string(uuid)]))
            notice = .done("Saved who gets this email.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    /// The counts belong to one list.
    var visibleAudiencePreview: MktCampAudiencePreview? { audiencePreviewFor == listUUID ? audiencePreview : nil }

    func previewAudience() async {
        busy = "Preview"
        defer { busy = nil }
        do {
            audiencePreview = try await api.audiencePreview(uuid, listUUID: listUUID)
            audiencePreviewFor = listUUID
            notice = nil
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    func saveBudget() async {
        switch MktCamp.budget(budget) {
        case .failure(let problem): notice = .info(problem.message)
        case .success(let n):
            await save(["max_deliveries": n.map { .number(Double($0)) } ?? .null],
                       done: n.map { "It now stops after \($0.formatted()) emails." } ?? "No limit on how many get it.")
        }
    }

    func saveBatches() async {
        switch MktCamp.batches(size: batchSize, every: batchEvery) {
        case .failure(let problem): notice = .info(problem.message)
        case .success(let body):
            let size = Int(batchSize.trimmingCharacters(in: .whitespaces))
            await save(body.objectValue ?? [:], done: size.map { "Sends \($0.formatted()) at a time, every \(batchEvery) minutes." }
                       ?? "Batches off: it sends as fast as allowed.")
        }
    }

    func sendTest() async {
        let address = testEmail.trimmingCharacters(in: .whitespaces)
        guard address.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil else {
            notice = .info("Type the email address to send the test to, like you@yourbusiness.co.uk.")
            return
        }
        busy = "Test"
        defer { busy = nil }
        testResult = nil
        do {
            let outcome = MktCamp.testSendOutcome(try await api.testSend(uuid, email: address), to: address)
            if outcome.ok { testResult = outcome.message; notice = .done(outcome.message) } else { notice = .info(outcome.message) }
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    func checkEligibility(contact: Record) async {
        busy = "Eligibility"
        defer { busy = nil }
        let name = [contact.string("first_name"), contact.string("last_name")].compactMap { $0 }.joined(separator: " ")
            .trimmedOrNil ?? contact.string("email") ?? "This person"
        do {
            let answer = MktCamp.eligibilityText(try await api.eligibility(uuid, contactUUID: contact.string("uuid") ?? contact.id))
            eligibility = (name, answer.allowed, answer.text)
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    // MARK: Tracking and A/B

    func saveTracking() async {
        await save(["tracking": tracking.json], done: "Tracking settings saved.")
    }

    func saveAB() async {
        if let problem = ab.problem(campaignSubject: campaign?.subject ?? "") {
            notice = .info(problem)
            return
        }
        busy = "A/B"
        defer { busy = nil }
        let before = status
        do {
            let saved = try await api.saveAB(uuid, ab)
            apply(saved)
            ab = savedAB
            let words = ab.enabled ? "A/B test saved and switched on." : "Versions saved (the test is off)."
            notice = before != .draft && saved.status == .draft
                ? .info("\(words) It went back to draft — press “Check it” again before sending.") : .done(words)
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Pictures for emails: the plugin takes PNG, JPEG, GIF or WebP up to 2 MB, so photos (often HEIC,
/// often large) are turned into a JPEG that fits.
enum MktCampImagePrep {
    static func isAccepted(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }   // PNG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }         // JPEG
        if bytes.starts(with: Array("GIF8".utf8)) { return true }         // GIF
        if bytes.count >= 12, bytes[0..<4] == ArraySlice(Array("RIFF".utf8)), bytes[8..<12] == ArraySlice(Array("WEBP".utf8)) {
            return true
        }
        return false
    }

    static func forEmail(_ file: EngageFile) -> EngageFile? {
        if isAccepted(file.data), file.data.count <= MktEmailImages.maxBytes { return file }
        guard let image = UIImage(data: file.data) else { return nil }
        let scale = min(1, 1200 / max(image.size.width, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        var quality: CGFloat = 0.85
        while quality > 0.2 {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= MktEmailImages.maxBytes {
                let base = (file.name as NSString).deletingPathExtension
                return EngageFile(name: (base.isEmpty ? "image" : base) + ".jpg", data: jpeg, mimeType: "image/jpeg")
            }
            quality -= 0.15
        }
        return nil
    }
}
