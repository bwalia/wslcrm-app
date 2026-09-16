import SwiftUI

/// The engineer's on-site screen (opsapi #610 "guided visit"). One primary action that changes
/// with the visit: On my way → I've arrived (GPS) → do the work → Finish. Manager concepts —
/// prices, approval, invoicing, status transitions — are not shown here.
struct GuidedVisitView: View {
    let visitUuid: String
    @Environment(\.services) private var services
    @Environment(SyncCenter.self) private var sync
    @Environment(SessionStore.self) private var session

    var body: some View {
        ModelHost(make: {
            VisitDetailViewModel(visitUuid: visitUuid, api: services.fieldService, sync: sync, session: session)
        }) { model in
            GuidedVisitContent(model: model)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GuidedVisitContent: View {
    @Bindable var model: VisitDetailViewModel
    @Environment(\.services) private var services
    @State private var quoteKind: QuoteLineSheet.Kind?
    @State private var showingFinish = false
    @State private var showingNoAccess = false
    @State private var photos: JobPhotosModel?

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded(let detail):
                if let visit = model.displayedVisit {
                    content(detail: detail, visit: visit)
                        .safeAreaInset(edge: .bottom, spacing: 0) { primaryActionBar(visit) }
                }
            }
        }
        .navigationTitle(model.displayedVisit?.jobNumber ?? "Job")
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $quoteKind) { kind in
            QuoteLineSheet(kind: kind, showsPrices: model.showsPrices) { body in
                await model.addItem(body)
            }
        }
        .sheet(isPresented: $showingFinish) {
            if let detail = model.detail {
                CheckOutSheet(visit: detail.visit, phase: detail.phase) { form in
                    await model.checkOut(form)
                }
            }
        }
        .sheet(isPresented: $showingNoAccess) {
            NoAccessSheet { reason in await model.markNoAccess(reason: reason) }
                .presentationDetents([.medium, .large])
        }
        .alert("Couldn't update the job", isPresented: .init(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
               presenting: model.actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
        .alert("Job finished", isPresented: .init(get: { !model.warnings.isEmpty }, set: { if !$0 { model.warnings = [] } }),
               presenting: model.warnings) { _ in
            Button("OK", role: .cancel) {}
        } message: { warnings in
            Text("The visit is complete, but:\n• " + warnings.joined(separator: "\n• "))
        }
        .alert("Saved offline", isPresented: .init(get: { model.queuedMessage != nil }, set: { if !$0 { model.queuedMessage = nil } }),
               presenting: model.queuedMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func content(detail: VisitDetail, visit: Visit) -> some View {
        let onSite = visit.status == .onSite
        let done = visit.status == .completed
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    WorkStatusBadge(visit: visit)
                        .accessibilityIdentifier("guided.status")
                    Text(visit.jobTitle.isEmpty ? "Service visit" : visit.jobTitle)
                        .font(.title.bold())
                    Text([visit.customerName ?? "No customer", visit.phaseName].compactMap { $0 }.joined(separator: " · "))
                        .font(.title3)
                        .foregroundStyle(.secondaryText)
                    if !model.pendingWrites.isEmpty {
                        PendingSyncBadge(failed: model.pendingWrites.contains(where: \.isFailed))
                    }
                    if let cachedAt = model.cachedAt { CachedDataNotice(savedAt: cachedAt) }
                }

                // Site + call
                HStack(spacing: 10) {
                    if let place = visit.fullAddress ?? visit.siteName {
                        Link(destination: MapsLink.url(for: [visit.siteName, visit.fullAddress].compactMap { $0 }.joined(separator: ", ")) ?? URL(string: "https://maps.apple.com")!) {
                            HStack(spacing: 12) {
                                Image(systemName: "location.fill").font(.title3).foregroundStyle(Tone.info.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(visit.siteName != nil ? "Site · tap for directions" : "Directions")
                                        .font(.caption).foregroundStyle(.secondaryText)
                                    Text(visit.siteName ?? place).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    if visit.siteName != nil, let address = visit.fullAddress {
                                        Text(address).font(.caption).foregroundStyle(.secondaryText).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(minHeight: 64)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .accessibilityLabel("Directions to \(visit.siteName ?? place)")
                    }
                    if let phone = visit.customerPhone, let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                        Link(destination: url) {
                            Image(systemName: "phone.fill")
                                .font(.title2)
                                .frame(width: 64, height: 64)
                                .background(Tone.success.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(Tone.success.color)
                        }
                        .accessibilityLabel("Call customer \(phone)")
                    }
                }

                if let notes = visit.siteAccessNotes, !notes.isEmpty {
                    Label(notes, systemImage: "key.fill")
                        .font(.subheadline)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tone.warning.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Access notes: \(notes)")
                }

                // What to fix
                card {
                    Label("What to fix", systemImage: "list.clipboard")
                        .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondaryText)
                    if let product = visit.productName {
                        Text("Unit: ").foregroundStyle(.secondaryText) + Text(product).bold()
                            + Text(visit.productRef.map { " · \($0)" } ?? "")
                    }
                    if let phase = visit.phaseName {
                        Text("Task: ").foregroundStyle(.secondaryText) + Text(phase).bold()
                    }
                    if let instructions = visit.instructions, !instructions.isEmpty {
                        Text(instructions)
                    } else if visit.productName == nil && visit.phaseName == nil {
                        Text("See the customer for details.").foregroundStyle(.secondaryText)
                    }
                }

                // Checklist
                if let phase = detail.phase, !phase.checklist.isEmpty {
                    card {
                        Text("Checklist · \(phase.checklist.count - phase.uncheckedCount) of \(phase.checklist.count)")
                            .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondaryText)
                        ForEach(Array(phase.checklist.enumerated()), id: \.offset) { index, item in
                            ChecklistRow(item: item, isPending: !model.pendingWrites.filter { $0.entityId == phase.uuid }.isEmpty,
                                         isEnabled: onSite) {
                                Task { await model.toggleChecklist(index: index) }
                            }
                            .accessibilityIdentifier("guided.checklist.\(index)")
                        }
                        if !onSite {
                            Text("Check in to tick the checklist.").font(.footnote).foregroundStyle(.secondaryText)
                        }
                    }
                }

                // On-site capture
                if onSite {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        CaptureTile(title: "Labour", hint: "Engineer / mate time", systemImage: "person.badge.clock") { quoteKind = .labour }
                            .accessibilityIdentifier("guided.tile.labour")
                        CaptureTile(title: "Materials", hint: "Parts fitted", systemImage: "shippingbox") { quoteKind = .material }
                            .accessibilityIdentifier("guided.tile.materials")
                        CaptureTile(title: "Hire", hint: "Tools / access", systemImage: "truck.box") { quoteKind = .hire }
                            .accessibilityIdentifier("guided.tile.hire")
                        FGasTile(visit: visit) { updated in model.replace(updated) }
                    }
                }

                if !detail.items.isEmpty || !model.pendingItemSummaries.isEmpty {
                    card {
                        Text("On this sheet")
                            .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondaryText)
                        QuoteSheetSummary(items: detail.items, showsPrices: model.showsPrices,
                                          currency: visit.jobCurrency ?? Formatters.fallbackCurrency)
                        ForEach(model.pendingItemSummaries) { pending in
                            HStack {
                                Text(pending.summary)
                                Spacer()
                                PendingSyncBadge(failed: pending.isFailed)
                            }
                        }
                    }
                    .accessibilityIdentifier("guided.sheet")
                }

                if onSite || visit.hasFGasRecord {
                    card { FGasCard(visit: visit, canEdit: onSite) { updated in model.replace(updated) } }
                        .id("fgas")
                }

                if let photos {
                    card { PhotosSection(model: photos, canEdit: onSite) }
                }

                if done {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Tone.success.color)
                            .accessibilityHidden(true)
                        Text("Job complete").font(.title3.bold())
                        if let summary = visit.workSummary { Text(summary).multilineTextAlignment(.center) }
                        if let hours = visit.labourHours { Text("\(hours.formatted()) h on site").font(.footnote).foregroundStyle(.secondaryText) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(Tone.success.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("guided.complete")
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            if photos == nil, !visit.jobUuid.isEmpty {
                photos = JobPhotosModel(jobUuid: visit.jobUuid, visitUuid: visit.uuid, api: services.fieldService)
            }
        }
    }

    @ViewBuilder
    private func primaryActionBar(_ visit: Visit) -> some View {
        VStack(spacing: 6) {
            switch visit.status {
            case .scheduled:
                actionButton("On my way", systemImage: "car.fill", tone: .info, id: "enRoute") {
                    Task { await model.markEnRoute() }
                }
                Button("I'm already here — check in") { Task { await model.checkIn() } }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .disabled(model.busy)
                    .accessibilityIdentifier("guided.action.checkInDirect")
            case .enRoute:
                actionButton("I've arrived", systemImage: "mappin.and.ellipse", tone: .success, id: "arrive") {
                    Task { await model.checkIn() }
                }
            case .onSite:
                actionButton("Finish job", systemImage: "checkmark.circle.fill", tone: .success, id: "finish") {
                    showingFinish = true
                }
            case .noAccess:
                Text("Marked no access — the office will rebook.").font(.subheadline).foregroundStyle(.secondaryText)
            default:
                EmptyView()
            }
            if visit.status.isOpen {
                Button("Can't get in? Record no access") { showingNoAccess = true }
                    .font(.subheadline)
                    .foregroundStyle(Tone.info.textColor)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
                    .disabled(model.busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        // Opaque, not `.bar`: work notes must never be read through the action bar.
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
        .opacity(visit.status.isOpen || visit.status == .noAccess ? 1 : 0)
    }

    private func actionButton(_ title: String, systemImage: String, tone: Tone, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if model.busy {
                ProgressView().tint(.white)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .buttonStyle(.large(tone))
        .disabled(model.busy)
        .accessibilityIdentifier("guided.action.\(id)")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CaptureTile: View {
    let title: String
    let hint: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage).font(.headline).foregroundStyle(.primary)
                Text(hint).font(.caption).foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(.separator)))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds a \(title.lowercased()) line to the quote sheet")
    }
}

/// Opens the F-Gas form straight from the capture grid.
private struct FGasTile: View {
    let visit: Visit
    let onSaved: (VisitDetail) -> Void
    @Environment(\.services) private var services
    @State private var editing = false

    var body: some View {
        CaptureTile(title: "Refrigerant", hint: visit.hasFGasRecord ? "F-Gas logged" : "F-Gas log", systemImage: "snowflake") {
            editing = true
        }
        .accessibilityIdentifier("guided.tile.refrigerant")
        .sheet(isPresented: $editing) {
            // Straight to the form: on site this is one tile tap, not tile then "Log F-Gas".
            FGasForm(visit: visit) { body in
                await FGasForm.save(visit: visit, body: body, api: services.fieldService) { updated in
                    onSaved(updated)
                    editing = false
                }
            }
        }
    }
}
