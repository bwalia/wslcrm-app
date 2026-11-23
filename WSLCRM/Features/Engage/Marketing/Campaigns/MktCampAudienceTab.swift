import SwiftUI

/// The Audience tab: which list gets it, who of them really can, a test to yourself, one person's
/// check, and the optional limits (send to at most…, send in batches).
struct MktCampAudienceSections: View {
    @Bindable var model: MktCampDetailModel
    @Environment(SessionStore.self) private var session

    private var canUpdate: Bool { session.permissions.can(.update, moduleName: Marketing.RBAC.campaigns) }
    private var canTest: Bool { session.permissions.can(.create, moduleName: Marketing.RBAC.campaigns) }
    /// The list can change while it can be edited, and while it is only scheduled.
    private var canChooseList: Bool { canUpdate && (model.editable || model.status == .scheduled) }
    private var campaignChannel: String { model.campaign?.channel ?? "email" }

    var body: some View {
        listSection
        if let preview = model.visibleAudiencePreview { previewSection(preview) }
        testSection
        eligibilitySection
        limitsSection
    }

    // MARK: Who gets it

    private var listSection: some View {
        Section {
            Picker("List", selection: Binding(get: { model.listUUID }, set: { uuid in Task { await model.chooseList(uuid) } })) {
                Text("Choose a list").tag("")
                ForEach(model.lists) { list in
                    Text(listLabel(list)).tag(list.uuid)
                }
            }
            .disabled(!canChooseList)
            .accessibilityIdentifier("mkt.audience.list")
            Button { Task { await model.previewAudience() } } label: {
                HStack {
                    Label("Who will get it?", systemImage: "eye")
                    if model.busy == "Preview" { Spacer(); ProgressView() }
                }
            }
            .disabled(!model.hasAudience || model.isBusy)
            .accessibilityIdentifier("mkt.audience.preview")
            if model.lists.isEmpty {
                Text("No lists yet. Make one from your contacts first.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let list = model.selectedList, list.isSmart {
                Label("Smart list — it fills itself from its rules just before sending.", systemImage: "wand.and.stars")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            if let list = model.selectedList, let channel = list.channel, channel != campaignChannel {
                Label("This list is for \(MktCamp.channelWords(channel)), but this campaign sends "
                      + "\(MktCamp.channelWords(campaignChannel)). Pick a list for \(MktCamp.channelWords(campaignChannel)).",
                      systemImage: "exclamationmark.triangle")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
            NavigationLink(value: NativeScreenRoute(Marketing.Screen.lists)) {
                Label(model.lists.isEmpty ? "Make a list" : "Manage lists", systemImage: "person.2")
            }
            .accessibilityIdentifier("mkt.audience.manageLists")
        } header: {
            Text("Who gets this email")
        } footer: {
            Text("If you change the list after pressing “Check it”, press it again before sending.")
        }
    }

    private func listLabel(_ list: MktCampList) -> String {
        var label = list.name
        if list.isSmart { label += " (smart list)" }
        if let channel = list.channel, channel != campaignChannel { label += " · \(channel)" }
        return label
    }

    private func previewSection(_ preview: MktCampAudiencePreview) -> some View {
        Section {
            MktCampTileGrid(tiles: [
                MktCampTile(label: "In the list", value: preview.total.formatted()),
                MktCampTile(label: "Will get it", value: preview.eligible.formatted(), tone: .success),
                MktCampTile(label: "Unsubscribed", value: preview.suppressed.formatted()),
                MktCampTile(label: "No permission", value: preview.noConsent.formatted()),
                MktCampTile(label: "No email address", value: preview.missingAddress.formatted()),
                MktCampTile(label: "Other", value: preview.other.formatted()),
            ])
            if !preview.exact {
                Text("A big list — the numbers are worked out from \((preview.sampled ?? 0).formatted()) people. Each "
                     + "person is checked again when it’s sent.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            ForEach(Array(MktCampAudiencePreview.reasons.enumerated()), id: \.offset) { _, reason in
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason.title).font(.wsSubheadline.weight(.semibold))
                    Text(reason.explain).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
        } header: {
            Text("Who will get it")
        }
    }

    // MARK: Test and checks

    @ViewBuilder
    private var testSection: some View {
        if canTest {
            Section {
                if model.testMode {
                    Label("Test mode is on, so nothing is really sent — not even this test.", systemImage: "flask")
                        .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                    NavigationLink(value: NativeScreenRoute(Marketing.Screen.settings)) {
                        Label("Switch test mode off in Marketing settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("mkt.audience.settings")
                }
                TextField("you@yourbusiness.co.uk", text: $model.testEmail)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.audience.testEmail")
                Button { Task { await model.sendTest() } } label: {
                    HStack {
                        Label("Send test", systemImage: "paperplane")
                        if model.busy == "Test" { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.testEmail.trimmedOrNil == nil || model.isBusy)
                .accessibilityIdentifier("mkt.audience.sendTest")
                if let result = model.testResult {
                    Label(result, systemImage: "checkmark.circle").font(.wsFootnote).foregroundStyle(Tone.success.textColor)
                }
            } header: {
                Text("Send yourself a test")
            } footer: {
                Text("See exactly what people will get. It sends the saved email to one address — yours, or anyone’s — "
                     + "and doesn’t add them to the list.")
            }
        }
    }

    private var eligibilitySection: some View {
        Section {
            Button { model.sheet = .contactPicker } label: {
                HStack {
                    Label("Would this person get it?", systemImage: "person.crop.circle.badge.questionmark")
                    if model.busy == "Eligibility" { Spacer(); ProgressView() }
                }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("mkt.audience.eligibility")
            if let check = model.eligibility {
                Label("\(check.name): \(check.text)", systemImage: check.allowed ? "checkmark.circle" : "xmark.circle")
                    .font(.wsSubheadline)
                    .foregroundStyle(check.allowed ? Tone.success.textColor : Tone.warning.textColor)
            }
        } header: {
            Text("Check one person")
        } footer: {
            Text("Pick a contact to see if they’d get this email, and if not, why (unsubscribed, no permission, no address…).")
        }
    }

    // MARK: Limits

    @ViewBuilder
    private var limitsSection: some View {
        let editable = canUpdate && model.editable
        Section {
            LabeledContent("Send to at most") {
                TextField("No limit", text: $model.budget)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("mkt.audience.budget")
            }
            .disabled(!editable)
            Button { Task { await model.saveBudget() } } label: { Label("Save limit", systemImage: "checkmark") }
                .disabled(!editable || !model.budgetDirty || model.isBusy)
                .accessibilityIdentifier("mkt.audience.budget.save")
        } header: {
            Text("More options (optional)")
        } footer: {
            Text("Stop after this many emails. Leave empty to send to everyone on the list.")
        }
        Section {
            LabeledContent("Per batch") {
                TextField("All at once", text: $model.batchSize)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("mkt.audience.batchSize")
            }
            LabeledContent("Minutes between batches") {
                TextField("60", text: $model.batchEvery)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("mkt.audience.batchEvery")
            }
            .disabled(model.batchSize.trimmedOrNil == nil)
            Button { Task { await model.saveBatches() } } label: { Label("Save batches", systemImage: "checkmark") }
                .disabled(!editable || !model.batchesDirty || model.isBusy)
                .accessibilityIdentifier("mkt.audience.batches.save")
            if let preview = model.visibleAudiencePreview,
               let estimate = MktCampAudiencePreview.batchEstimate(eligible: preview.eligible,
                                                                   batchSize: Int(model.batchSize) ?? 0,
                                                                   minutesBetween: Int(model.batchEvery) ?? 0) {
                Text(estimate).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Send in batches")
        } footer: {
            Text("For big lists: send this many at once, then the next batch after a pause. Leave empty to send "
                 + "everything as fast as the workspace allows.")
        }
        .disabled(!editable)
    }
}
