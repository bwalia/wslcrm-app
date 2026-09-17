import SwiftUI

// Customer assets: the individual machines at customer sites, as Simpro holds them.
// Engineers survey them on site (condition 1–6, readings, F-Gas); managers review the register.

struct CustomerAssetRoute: Hashable { let uuid: String }

@MainActor
@Observable
final class CustomerAssetsModel {
    var filter = SimproAPI.AssetFilter() { didSet { holder.filter = filter } }
    let list: PagedListModel<CustomerAsset>

    @ObservationIgnored private let holder = FilterHolder()

    @MainActor
    private final class FilterHolder { var filter = SimproAPI.AssetFilter() }

    init(api: SimproAPI) {
        let holder = self.holder
        list = PagedListModel<CustomerAsset> { search, page in
            try await api.assets(search: search, filter: holder.filter, page: page)
        }
    }
}

struct CustomerAssetsListView: View {
    @Environment(\.services) private var services

    var body: some View {
        ModelHost(make: { CustomerAssetsModel(api: services.simpro) }) { model in
            CustomerAssetsContent(model: model)
        }
        .navigationTitle("Assets")
    }
}

private struct CustomerAssetsContent: View {
    @Bindable var model: CustomerAssetsModel

    var body: some View {
        PagedList(model: model.list, searchPrompt: "Tag, description, serial or model",
                  emptyTitle: "No assets", emptySystemImage: "air.conditioner.horizontal",
                  emptyDescription: "Customer plant under maintenance appears here once it is in the register.") { asset in
            NavigationLink(value: CustomerAssetRoute(uuid: asset.uuid)) {
                CustomerAssetRow(asset: asset)
            }
            .accessibilityIdentifier("customerAsset.row.\(asset.assetTag ?? asset.name)")
        }
        .safeAreaInset(edge: .top) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "Overdue", isOn: $model.filter.serviceOverdue)
                        .accessibilityIdentifier("customerAssets.filter.overdue")
                    FilterChip(title: "F-Gas", isOn: $model.filter.fgasOnly)
                    FilterChip(title: "Condition 4+", isOn: Binding(
                        get: { model.filter.conditionMin == 4 },
                        set: { model.filter.conditionMin = $0 ? 4 : nil }))
                        .accessibilityIdentifier("customerAssets.filter.condition")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        .onChange(of: model.filter) { _, _ in Task { await model.list.load() } }
    }
}

private struct FilterChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(isOn ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct CustomerAssetRow: View {
    let asset: CustomerAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(asset.name).font(.headline)
                Spacer()
                if let tag = asset.assetTag {
                    Text(tag).font(.caption.monospaced()).foregroundStyle(.secondaryText)
                }
            }
            Text([asset.customerName, asset.siteName].compactMap { $0 }.joined(separator: " — "))
                .font(.subheadline).foregroundStyle(.secondaryText)
            HStack(spacing: 6) {
                if let rating = asset.conditionRating {
                    StatusBadge(text: "\(rating) · \(ConditionRating.label(rating))", systemImage: "gauge.with.dots.needle.33percent",
                                tone: ConditionRating.tone(rating))
                }
                if asset.isServiceOverdue() {
                    StatusBadge(text: "Service overdue", systemImage: "exclamationmark.triangle", tone: .danger)
                }
                if let refrigerant = asset.refrigerantType {
                    StatusBadge(text: refrigerant, systemImage: "snowflake", tone: .info)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct CustomerAssetDetailView: View {
    let assetUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var asset: LoadState<CustomerAsset> = .idle
    @State private var surveying = false
    @State private var historyPDF: ExportedFile?
    @State private var exportError: APIError?
    @State private var exporting = false

    var body: some View {
        List {
            switch asset {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let asset):
                content(asset)
            }
        }
        .navigationTitle(asset.value?.assetTag ?? "Asset")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.permissions.can(.read, .fsReports) {
                ToolbarItem(placement: .topBarTrailing) {
                    if let historyPDF {
                        ShareLink(item: historyPDF.url) { Label("Asset history PDF", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("customerAsset.sharePDF")
                    } else {
                        Button { Task { await exportHistory() } } label: {
                            if exporting { ProgressView() } else { Label("Asset history PDF", systemImage: "doc.richtext") }
                        }
                        .disabled(exporting)
                        .accessibilityIdentifier("customerAsset.historyPDF")
                    }
                }
            }
        }
        .sheet(isPresented: $surveying) {
            if let value = asset.value {
                RecordSurveySheet(asset: value) { await load() }
            }
        }
        .alert("Couldn't build the PDF", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError?.localizedDescription ?? "")
        }
    }

    @ViewBuilder
    private func content(_ asset: CustomerAsset) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(asset.name).font(.title2.bold())
                Text([asset.customerName, asset.siteName].compactMap { $0 }.joined(separator: " — "))
                    .foregroundStyle(.secondaryText)
                HStack(spacing: 6) {
                    if let rating = asset.conditionRating {
                        StatusBadge(text: "\(rating) · \(ConditionRating.label(rating))", systemImage: "gauge.with.dots.needle.33percent",
                                    tone: ConditionRating.tone(rating))
                    }
                    StatusBadge(text: asset.syncState.label, systemImage: asset.syncState.systemImage, tone: asset.syncState.tone)
                        .accessibilityIdentifier("customerAsset.syncState")
                }
            }
            .padding(.vertical, 4)
            if let notes = asset.conditionNotes, !notes.isEmpty {
                Label(notes, systemImage: "exclamationmark.bubble").foregroundStyle(Tone.warning.textColor)
            }
            if session.permissions.can(.update, .fsAssets) {
                Button { surveying = true } label: {
                    Label("Record a survey", systemImage: "checklist")
                }
                .buttonStyle(.large(.info))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("customerAsset.recordSurvey")
            }
        }

        Section("Details") {
            detail("Type", asset.assetType)
            detail("Manufacturer", [asset.manufacturer, asset.model].compactMap { $0 }.joined(separator: " "))
            detail("Serial", asset.serialNumber)
            detail("Location", asset.locationDetail)
            detail("Installed", asset.installedAt.map { SimproDates.display($0) })
            detail("Contract", asset.contractName)
            detail("Last surveyed", asset.lastSurveyedAt.map { SimproDates.display($0) })
        }

        if let refrigerant = asset.refrigerantType {
            Section("F-Gas") {
                detail("Refrigerant", refrigerant)
                detail("Charge", asset.refrigerantChargeKg.map { "\($0) kg" })
                detail("CO₂ equivalent", asset.co2eTonnes.map { "\($0) t" })
                detail("Leak check", asset.leakCheckMonths.map { "Every \($0) months" } ?? "Not required")
                detail("Next leak check", asset.nextLeakCheckAt.map { SimproDates.display($0) })
            }
        }

        Section("Service schedule") {
            if asset.serviceLevels.isEmpty { Text("No service levels").foregroundStyle(.secondaryText) }
            ForEach(asset.serviceLevels) { level in
                let overdue = (SimproDates.day(level.nextServiceDate) ?? .distantFuture) < Calendar.current.startOfDay(for: Date())
                VStack(alignment: .leading, spacing: 4) {
                    Text(level.name).font(.headline)
                    Text("Every \(level.frequencyMonths) months · last \(SimproDates.display(level.lastServiceDate))")
                        .font(.subheadline).foregroundStyle(.secondaryText)
                    Text("Next due \(SimproDates.display(level.nextServiceDate))")
                        .font(.subheadline.weight(overdue ? .semibold : .regular))
                        .foregroundStyle(overdue ? Tone.danger.textColor : .primary)
                }
                .accessibilityElement(children: .combine)
            }
        }

        Section("Survey history") {
            if asset.recentTests.isEmpty { Text("Not surveyed yet").foregroundStyle(.secondaryText) }
            ForEach(asset.recentTests) { test in
                SurveyRow(test: test)
            }
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }

    private func load() async {
        if asset.value == nil { asset = .loading }
        do {
            asset = .loaded(try await services.simpro.asset(assetUuid))
        } catch {
            if asset.value == nil { asset = .failed(error.asAPIError) }
        }
    }

    private func exportHistory() async {
        exporting = true
        defer { exporting = false }
        do {
            let report = try await services.simpro.report("asset_history", query: ReportQuery(assetUuid: assetUuid))
            let data = ReportPDFRenderer(company: Brand.current.company).render(report)
            historyPDF = try ExportedFile.write(data, named: "asset-history-\(self.asset.value?.assetTag ?? assetUuid).pdf")
        } catch {
            exportError = error.asAPIError
        }
    }
}

private struct SurveyRow: View {
    let test: AssetTest

    private var tone: Tone {
        switch test.result {
        case "fail": .danger
        case "advisory": .warning
        default: .success
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(SimproDates.display(test.testedAt)).font(.headline)
                Spacer()
                StatusBadge(text: test.result.capitalized, systemImage: tone == .success ? "checkmark" : "exclamationmark",
                            tone: tone)
            }
            Text([test.serviceLevel, test.technicianName, test.conditionRating.map { "Condition \($0)" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondaryText)
            let readings = test.readings.filter { $0.key != "condition" && $0.value != nil && $0.value != .null }
            if !readings.isEmpty {
                Text(readings.map { "\($0.label): \($0.displayValue)" }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondaryText)
            }
            if !test.failurePoints.isEmpty {
                Label(test.failurePoints.map(\.label).joined(separator: ", "), systemImage: "xmark.octagon")
                    .font(.footnote).foregroundStyle(Tone.danger.textColor)
            }
            if let notes = test.notes, !notes.isEmpty {
                Text(notes).font(.footnote)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct RecordSurveySheet: View {
    let asset: CustomerAsset
    let onSaved: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var condition: Int
    @State private var result = "pass"
    @State private var levelUuid: String?
    @State private var refrigerantAdded = ""
    @State private var leakCheck = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var error: APIError?

    init(asset: CustomerAsset, onSaved: @escaping () async -> Void) {
        self.asset = asset
        self.onSaved = onSaved
        _condition = State(initialValue: asset.conditionRating ?? 2)
        _levelUuid = State(initialValue: asset.serviceLevels.first?.uuid)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Condition") {
                    Picker("Condition", selection: $condition) {
                        ForEach(1...6, id: \.self) { rating in
                            Text("\(rating) — \(ConditionRating.label(rating))").tag(rating)
                        }
                    }
                    .accessibilityIdentifier("survey.condition")
                    Picker("Result", selection: $result) {
                        Text("Pass").tag("pass")
                        Text("Advisory").tag("advisory")
                        Text("Fail").tag("fail")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("survey.result")
                }
                if !asset.serviceLevels.isEmpty {
                    Section("Schedule") {
                        Picker("Against", selection: $levelUuid) {
                            ForEach(asset.serviceLevels) { Text($0.name).tag(Optional($0.uuid)) }
                        }
                    }
                }
                if asset.refrigerantType != nil {
                    Section("F-Gas") {
                        TextField("Refrigerant added (kg)", text: $refrigerantAdded)
                            .keyboardType(.decimalPad)
                        Picker("Leak check", selection: $leakCheck) {
                            Text("Not done").tag("")
                            Text("Pass").tag("pass")
                            Text("Fail").tag("fail")
                        }
                    }
                }
                Section("Notes") {
                    TextField("What was found and done", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("survey.notes")
                }
                if let error {
                    Section { Text(error.localizedDescription).foregroundStyle(Tone.danger.textColor) }
                }
            }
            .navigationTitle("Survey \(asset.assetTag ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving)
                        .accessibilityIdentifier("survey.save")
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body = RecordSurveyBody(
            conditionRating: condition, result: result, serviceLevelUuid: levelUuid,
            refrigerantAddedKg: Decimal(string: refrigerantAdded.replacingOccurrences(of: ",", with: ".")),
            leakCheckResult: leakCheck.isEmpty ? nil : leakCheck,
            notes: notes.isEmpty ? nil : notes,
            readings: [.init(key: "condition", label: "Condition rating (1 excellent – 6 replace)", value: condition)])
        do {
            try await services.simpro.recordSurvey(assetUuid: asset.uuid, body: body)
            await onSaved()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A file written to the temporary directory for sharing.
struct ExportedFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }

    static func write(_ data: Data, named name: String) throws -> ExportedFile {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        return ExportedFile(url: url)
    }
}
