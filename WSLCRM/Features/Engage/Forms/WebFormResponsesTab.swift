import QuickLook
import SwiftUI

/// The Responses tab: newest first, search, status and date filters, refresh, CSV and PDF export, and each
/// response with the records it created or matched, its files, Not spam / Spam / Retry / Delete.
struct WebFormResponsesTab: View {
    let form: WebFormDetail
    @Environment(\.services) private var services
    @State private var items: [WebFormSubmission] = []
    @State private var columns: [WebFormColumn] = []
    @State private var next: String?
    @State private var state: LoadState<Void> = .idle
    @State private var loadingMore = false
    @State private var filter = WebFormsAPI.ResponseFilter()
    @State private var status = ""
    @State private var showingDates = false
    @State private var exporting = false
    @State private var exported: URL?
    @State private var pdf: URL?
    @State private var makingPDF = false
    @State private var notice: EngageNotice?
    @State private var hasAppeared = false

    var body: some View {
        List {
            Section { controls }
            if let notice { Section { EngageNoticeBar(notice: notice) } }
            ForEach(items) { submission in
                NavigationLink {
                    WebFormResponseDetailView(form: form, submissionID: submission.uuid, seed: submission) { change in
                        switch change {
                        case .changed(let updated):
                            if let index = items.firstIndex(where: { $0.uuid == updated.uuid }) { items[index] = updated }
                        case .deleted(let id):
                            items.removeAll { $0.uuid == id }
                        }
                    }
                } label: {
                    WebFormResponseRow(submission: submission, columns: Array(columns.prefix(3)))
                }
                .accessibilityIdentifier("forms.responses.row.\(submission.uuid)")
                .task { await loadMoreIfNeeded(submission) }
            }
            if loadingMore { HStack { Spacer(); ProgressView(); Spacer() } }
        }
        .overlay { overlay }
        .searchable(text: $filter.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search answers or email")
        .wsRefreshable { await load() }
        .task(id: filter) {
            if hasAppeared { try? await Task.sleep(for: .milliseconds(300)) }
            hasAppeared = true
            guard !Task.isCancelled else { return }
            await load()
        }
        .sheet(isPresented: $showingDates) {
            NavigationStack { WebFormDateRangeView(from: $filter.from, to: $filter.to) }
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("Show", selection: Binding(get: { filter.status ?? "" }, set: { filter.status = $0.isEmpty ? nil : $0 })) {
            Text("All responses (not spam)").tag("")
            Text("Needs attention").tag("needs_attention")
            Text("Complete").tag("complete")
            Text("Spam").tag("spam")
            Text("Everything, spam included").tag("all")
        }
        .accessibilityIdentifier("forms.responses.status")
        Button { showingDates = true } label: {
            LabeledContent("Received") {
                Text(dateText).foregroundStyle(filter.from == nil && filter.to == nil ? .secondaryText : .primary)
            }
        }
        .accessibilityIdentifier("forms.responses.dates")
        HStack {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless)
            Spacer()
            if let exported {
                ShareLink(item: exported) { Label("Save the CSV", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
            } else {
                Button { Task { await export() } } label: {
                    HStack { if exporting { ProgressView() }; Label("Export CSV", systemImage: "tablecells") }
                }
                .buttonStyle(.borderless)
                .disabled(exporting)
                .accessibilityIdentifier("forms.responses.export")
            }
        }
        HStack {
            Spacer()
            if let pdf {
                ShareLink(item: pdf) { Label("Share the PDF", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
            } else {
                Button { Task { await makePDF() } } label: {
                    HStack { if makingPDF { ProgressView() }; Label("Save as PDF", systemImage: "doc.richtext") }
                }
                .buttonStyle(.borderless)
                .disabled(makingPDF || items.isEmpty)
                .accessibilityIdentifier("forms.responses.pdf")
            }
        }
    }

    private var dateText: String {
        switch (filter.from, filter.to) {
        case (nil, nil): return "Any time"
        case (let from?, nil): return "From \(Formatters.day(from) ?? "")"
        case (nil, let to?): return "Up to \(Formatters.day(to) ?? "")"
        case (let from?, let to?): return "\(Formatters.day(from) ?? "") – \(Formatters.day(to) ?? "")"
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch state {
        case .idle:
            ProgressView()
        case .loading where items.isEmpty:
            ProgressView()
        case .failed(let error) where items.isEmpty:
            ErrorStateView(error: error) { Task { await load() } }
        case .loaded where items.isEmpty:
            ContentUnavailableView {
                Label(isFiltered ? "No responses match" : "No responses yet", systemImage: "tray")
            } description: {
                if !isFiltered { Text("Share the link to start collecting them.") }
            }
        default:
            EmptyView()
        }
    }

    private var isFiltered: Bool {
        filter.status != nil || filter.query.trimmedOrNil != nil || filter.from != nil || filter.to != nil
    }

    private func load() async {
        if items.isEmpty { state = .loading }
        exported = nil
        pdf = nil
        do {
            let page = try await services.webForms.responses(form.uuid, filter: filter, cursor: nil)
            items = page.items
            columns = page.columns
            next = page.next
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if items.isEmpty { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func loadMoreIfNeeded(_ submission: WebFormSubmission) async {
        guard submission.id == items.last?.id, let cursor = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await services.webForms.responses(form.uuid, filter: filter, cursor: cursor)
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            next = page.next
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    /// Every response the filter shows, in one PDF.
    private func makePDF() async {
        makingPDF = true
        defer { makingPDF = false }
        do {
            let all = try await WebFormResponsesPDF.all(services.webForms, form: form.uuid, filter: filter)
            let count = "\(all.items.count) response\(all.items.count == 1 ? "" : "s")"
            guard let url = WebFormResponsesPDF.file(
                title: form.title, subtitle: "\(count) · received \(dateText.lowercased()) · made \(Formatters.dateTime(Date()) ?? "")",
                entries: WebFormResponsesPDF.entries(fields: all.columns, submissions: all.items),
                name: WebFormResponsesPDF.filename(form.title, suffix: "responses")) else {
                throw ResourceService.problem(500, "The PDF couldn't be made. Try again.")
            }
            pdf = url
            notice = .done("The PDF is ready (\(count)): tap “Share the PDF” to keep or send it.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            exported = try await services.webForms.exportCSV(form.uuid, filter: filter, title: form.title)
            notice = .done("The CSV is ready: tap “Save the CSV” to keep or send it.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Choose the days responses were received between.
private struct WebFormDateRangeView: View {
    @Binding var from: Date?
    @Binding var to: Date?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            row("From", $from)
            row("Up to and including", $to)
            if from != nil || to != nil {
                Button("Any time", role: .destructive) { from = nil; to = nil }
            }
        }
        .navigationTitle("Received")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    @ViewBuilder
    private func row(_ label: String, _ date: Binding<Date?>) -> some View {
        if let value = date.wrappedValue {
            HStack {
                DatePicker(label, selection: Binding(get: { value }, set: { date.wrappedValue = $0 }),
                           displayedComponents: .date)
                Button { date.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondaryText)
                    .accessibilityLabel("Clear \(label)")
            }
        } else {
            Button { date.wrappedValue = Date() } label: {
                LabeledContent(label) { Text("Any").foregroundStyle(.tint) }
            }
        }
    }
}

/// One response in the list: when, the first answers, the records, its status.
struct WebFormResponseRow: View {
    let submission: WebFormSubmission
    let columns: [WebFormColumn]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(WebFormText.ago(submission.createdAt)).font(.wsHeadline)
                Spacer()
                StatusBadge(text: submission.status.label, systemImage: symbol, tone: submission.status.tone)
            }
            ForEach(columns, id: \.field.key) { column in
                let text = WebFormRules.show(column.field, column.field.key.flatMap { submission.answers[$0] })
                if !text.isEmpty {
                    Text("\(column.field.label): \(text)").font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(1)
                }
            }
            if !submission.links.isEmpty {
                HStack(spacing: 6) {
                    ForEach(submission.links, id: \.target) { link in
                        Pill(text: link.summary, systemImage: link.failed ? "exclamationmark.triangle" : nil,
                             foreground: link.failed ? Tone.warning.textColor : .secondaryText)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch submission.status {
        case .complete: "checkmark.circle"
        case .needsAttention: "exclamationmark.triangle"
        case .spam: "xmark.octagon"
        }
    }
}

enum WebFormResponseChange {
    case changed(WebFormSubmission)
    case deleted(String)
}

/// One response: every answer (tables as tables, files to open), the records it created or matched (opening
/// the customer or lead), where it came from, and Not spam / Spam / Retry / Delete.
struct WebFormResponseDetailView: View {
    let form: WebFormDetail
    let submissionID: String
    var seed: WebFormSubmission?
    var onChange: (WebFormResponseChange) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var submission: WebFormSubmission?
    @State private var loadError: APIError?
    @State private var notice: EngageNotice?
    @State private var busy: String?
    @State private var confirmingDelete = false
    @State private var openedFile: URL?
    @State private var openingFile: String?
    @State private var pdf: URL?

    private var canUpdate: Bool { session.permissions.can(.update, moduleName: WebFormsAPI.module) }
    private var canDelete: Bool { session.permissions.can(.delete, moduleName: WebFormsAPI.module) }

    var body: some View {
        List {
            if let notice { Section { EngageNoticeBar(notice: notice) } }
            if let submission {
                content(submission)
            } else if let loadError {
                InlineErrorRow(error: loadError) { Task { await load() } }
            }
        }
        .wsDetailList()
        .overlay { if submission == nil && loadError == nil { ProgressView() } }
        .navigationTitle("Response")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .quickLookPreview($openedFile)
        .confirmationDialog("Delete this response?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The answers are deleted for good. Customers, leads or invitations it created stay.")
        }
    }

    @ViewBuilder
    private func content(_ s: WebFormSubmission) -> some View {
        Section {
            Text("Received \(Formatters.dateTime(s.createdAt.flatMap(APIDate.parse)) ?? s.createdAt ?? "")"
                 + (s.respondentEmail.map { " from \($0)" } ?? ""))
                .font(.wsSubheadline)
            if s.status == .spam {
                Label("Marked as spam\(s.spamReason.map { " (\(Formatters.humanize($0).lowercased()))" } ?? ""): no "
                      + "records were created and no emails sent.", systemImage: "xmark.octagon")
                    .foregroundStyle(Tone.danger.textColor)
            }
            ForEach(s.links.filter(\.failed), id: \.target) { link in
                Label("\(WebFormTargetType(rawValue: link.target)?.label ?? link.target) not created: \(link.problem ?? "")",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.warning.textColor)
            }
        }
        Section("Answers") {
            let answerFields = s.fields.filter { $0.key != nil && $0.type.isInput }
            if answerFields.isEmpty { Text("No answers.").foregroundStyle(.secondaryText) }
            ForEach(answerFields) { field in answer(field, s) }
        }
        if !s.links.isEmpty {
            Section("Records") {
                ForEach(s.links, id: \.target) { link in WebFormLinkRow(link: link) }
            }
        }
        Section("Where it came from") {
            if let page = s.pageURL { DetailRow(label: "Page", value: page) }
            if let referrer = s.referrer { DetailRow(label: "Came from", value: referrer) }
            if !s.utm.isEmpty {
                DetailRow(label: "Campaign", value: s.utm.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", "))
            }
            if let ms = s.durationMS { DetailRow(label: "Time to fill in", value: "\(Int((ms / 1000).rounded())) s") }
            if let version = s.version { DetailRow(label: "Form version", value: "\(version)") }
        }
        Section {
            if let pdf {
                ShareLink(item: pdf) { Label("Share the PDF", systemImage: "square.and.arrow.up") }
            } else {
                Button { makePDF(s) } label: { Label("Save as PDF", systemImage: "doc.richtext") }
                    .accessibilityIdentifier("forms.response.pdf")
            }
        }
        actions(s)
    }

    @ViewBuilder
    private func answer(_ field: WebFormField, _ s: WebFormSubmission) -> some View {
        let value = field.key.flatMap { s.answers[$0] }
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label).font(.wsCaption).foregroundStyle(.secondaryText)
            if field.type == .fileUpload, let files = value?.arrayValue, !files.isEmpty {
                ForEach(files.compactMap(WebFormFileAnswer.init(json:))) { file in
                    Button { Task { await open(file, s) } } label: {
                        HStack {
                            Label(file.name, systemImage: "paperclip").lineLimit(1)
                            Spacer()
                            if openingFile == file.id { ProgressView() } else {
                                Text(file.sizeText).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    .accessibilityIdentifier("forms.response.file.\(file.id)")
                }
            } else if field.type == .table, let rows = value?.arrayValue, !rows.isEmpty {
                WebFormAnswerTable(field: field, rows: rows)
            } else {
                let text = WebFormRules.show(field, value)
                Text(text.isEmpty ? "—" : text).font(.wsBody).textSelection(.enabled)
                    .foregroundStyle(text.isEmpty ? .secondaryText : .primary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actions(_ s: WebFormSubmission) -> some View {
        if canUpdate || canDelete {
            Section {
                if canUpdate && s.status == .spam {
                    actionButton("Not spam", "checkmark.shield", id: "ham") {
                        try await services.webForms.setResponseStatus(form.uuid, id: s.uuid, status: "complete")
                    } done: { "Marked as not spam." }
                }
                if canUpdate && s.status != .spam {
                    actionButton("Spam", "xmark.shield", id: "spam") {
                        try await services.webForms.setResponseStatus(form.uuid, id: s.uuid, status: "spam")
                    } done: { "Marked as spam." }
                }
                if canUpdate && s.status != .spam && s.links.contains(where: \.failed) {
                    actionButton("Retry", "arrow.clockwise", id: "retry") {
                        try await services.webForms.retry(form.uuid, id: s.uuid)
                    } done: { "Retried." }
                }
                if canDelete {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete this response", systemImage: "trash")
                    }
                    .disabled(busy != nil)
                    .accessibilityIdentifier("forms.response.delete")
                }
            }
        }
    }

    private func actionButton(_ title: String, _ image: String, id: String,
                              run: @escaping () async throws -> WebFormSubmission,
                              done: @escaping () -> String) -> some View {
        Button {
            Task {
                busy = id
                defer { busy = nil }
                do {
                    let updated = try await run()
                    submission = updated
                    onChange(.changed(updated))
                    notice = .done(done())
                } catch {
                    notice = .failed(error.asAPIError)
                }
            }
        } label: {
            HStack { if busy == id { ProgressView() }; Label(title, systemImage: image) }
        }
        .disabled(busy != nil)
        .accessibilityIdentifier("forms.response.\(id)")
    }

    private func makePDF(_ s: WebFormSubmission) {
        pdf = WebFormResponsesPDF.file(title: form.title, subtitle: "One response",
                                       entries: WebFormResponsesPDF.entries(fields: [], submissions: [s]),
                                       name: WebFormResponsesPDF.filename(form.title, suffix: "response"))
        notice = pdf == nil ? .failed(ResourceService.problem(500, "The PDF couldn't be made. Try again."))
                            : .done("The PDF is ready: tap “Share the PDF” to keep or send it.")
    }

    private func load() async {
        if submission == nil, let seed, !seed.fields.isEmpty { submission = seed }
        do {
            submission = try await services.webForms.response(form.uuid, id: submissionID)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    /// Files open through a short-lived link: downloaded here and shown with Quick Look.
    private func open(_ file: WebFormFileAnswer, _ s: WebFormSubmission) async {
        openingFile = file.id
        defer { openingFile = nil }
        do {
            let link = try await services.webForms.fileLink(form.uuid, id: s.uuid, file: file.id)
            let (data, _) = try await URLSession.shared.data(from: link)
            openedFile = try EngageExport.temporaryFile(data, name: file.name)
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        busy = "delete"
        defer { busy = nil }
        do {
            try await services.webForms.deleteResponse(form.uuid, id: submissionID)
            onChange(.deleted(submissionID))
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// A table answer as a table.
struct WebFormAnswerTable: View {
    let field: WebFormField
    let rows: [JSONValue]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(field.columns, id: \.key) { Text($0.label).font(.wsCaption.weight(.semibold)) }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(field.columns, id: \.key) { column in
                            Text(row[column.key]?.stringValue ?? "")
                                .font(.wsSubheadline.monospacedDigit())
                                .gridColumnAlignment(column.number ? .trailing : .leading)
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

/// A record a response made or matched; customers and leads open their own screens.
struct WebFormLinkRow: View {
    let link: WebFormSubmissionLink

    var body: some View {
        if let uuid = link.entityUUID, !link.missing, link.entityType == "customer" {
            NavigationLink { CustomerDetailView(customerUuid: uuid) } label: { label }
        } else if let uuid = link.entityUUID, !link.missing, link.entityType == "lead" {
            NavigationLink { LeadDetailView(leadUuid: uuid) } label: { label }
        } else {
            label
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(link.summary).font(.wsHeadline)
                .foregroundStyle(link.failed ? Tone.warning.textColor : .primary)
            let who = link.recordName ?? link.recordEmail ?? (link.missing ? "deleted since" : nil)
            let invitation = link.entityType == "invitation" ? link.recordStatus.map { "invitation \($0)" } : nil
            let line = [who, invitation].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty { Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText) }
        }
        .accessibilityElement(children: .combine)
    }
}
