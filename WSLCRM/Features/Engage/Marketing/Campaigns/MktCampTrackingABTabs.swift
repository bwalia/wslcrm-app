import SwiftUI

/// The Tracking tab: opens, clicks, website attribution, UTM tags and the conversion goal.
struct MktCampTrackingSections: View {
    @Bindable var model: MktCampDetailModel
    @Environment(SessionStore.self) private var session

    private var canEdit: Bool { model.editable && session.permissions.can(.update, moduleName: Marketing.RBAC.campaigns) }

    var body: some View {
        if !model.editable {
            Section {
                Label("Tracking settings are locked while the campaign is \(model.status.label.lowercased()).",
                      systemImage: "lock")
                    .foregroundStyle(Tone.warning.textColor)
            }
        }
        Section {
            toggle("Count opens", "Adds an invisible picture. Opens are estimates — some email apps load pictures for "
                   + "privacy; known robots are left out.", $model.tracking.trackOpens, id: "opens")
            toggle("Count clicks", "Links go through a short redirect so each person’s clicks are counted. Robot clicks "
                   + "are left out.", $model.tracking.trackClicks, id: "clicks")
            toggle("Link sales on your website to this email", "Adds a small _mkt tag to links so the website pixel can "
                   + "credit visits and sales to this send.", $model.tracking.attribution, id: "attribution")
        } header: {
            Text("What to count")
        }
        .disabled(!canEdit)
        utmSection
        goalSection
        if canEdit {
            Section {
                Button { Task { await model.saveTracking() } } label: {
                    Label("Save tracking", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.trackingDirty || model.isBusy)
                .accessibilityIdentifier("mkt.tracking.save")
            } footer: {
                Text(model.trackingDirty ? "You have changes that aren’t saved yet." : "Everything is saved.")
            }
        }
    }

    private func toggle(_ title: String, _ help: String, _ isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityIdentifier("mkt.tracking.\(id)")
    }

    @ViewBuilder
    private var utmSection: some View {
        let campaign = model.campaign
        let channel = campaign?.channel ?? "email"
        Section {
            toggle("Add UTM tags to links", "So Google Analytics and other tools credit this campaign. Tags already on a "
                   + "link are kept.", $model.tracking.utmEnabled, id: "utm")
            utmField("Source", text: $model.tracking.utmSource, placeholder: "opsapi", id: "source")
            utmField("Medium", text: $model.tracking.utmMedium, placeholder: channel == "sms" ? "sms" : "email", id: "medium")
            utmField("Campaign", text: $model.tracking.utmCampaign,
                     placeholder: MktCamp.slugify(campaign?.name ?? "").trimmedOrNil ?? "campaign", id: "campaign")
            utmField("Content", text: $model.tracking.utmContent,
                     placeholder: campaign?.abEnabled == true ? "version name (e.g. A)" : "optional", id: "content")
            VStack(alignment: .leading, spacing: 4) {
                Text("Example tagged link").font(.wsCaption).foregroundStyle(.secondaryText)
                Text(model.tracking.exampleURL(campaignName: campaign?.name ?? "", campaignUUID: campaign?.uuid ?? "",
                                               channel: channel, abEnabled: campaign?.abEnabled ?? false))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("UTM tags")
        } footer: {
            Text("Empty boxes use the grey defaults.")
        }
        .disabled(!canEdit)
    }

    private func utmField(_ label: String, text: Binding<String>, placeholder: String, id: String) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mkt.tracking.utm.\(id)")
        }
        .disabled(!model.tracking.utmEnabled)
    }

    private var goalSection: some View {
        Section {
            Picker("Goal", selection: Binding(
                get: { model.customGoal ? "__custom__" : model.tracking.goalEvent },
                set: { value in
                    if value == "__custom__" {
                        model.customGoal = true
                        model.tracking.goalEvent = ""
                    } else {
                        model.customGoal = false
                        model.tracking.goalEvent = value
                    }
                })) {
                ForEach(MktCampTracking.goals) { Text($0.label).tag($0.value) }
                Text("Something else…").tag("__custom__")
            }
            .accessibilityIdentifier("mkt.tracking.goal")
            if model.customGoal {
                LabeledContent("Event name") {
                    TextField("e.g. quote_requested", text: $model.tracking.goalEvent)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mkt.tracking.goal.custom")
                }
            }
            NavigationLink(value: NativeScreenRoute(Marketing.Screen.pixels)) {
                Label("Set up the website pixel", systemImage: "dot.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("mkt.tracking.pixels")
        } header: {
            Text("What counts as a sale or sign-up")
        } footer: {
            Text("A sale or sign-up on your website is credited to the last campaign link that person clicked, within "
                 + "the pixel’s time window. It needs “Link sales on your website” above and the pixel on your site.")
        }
        .disabled(!canEdit)
    }
}

/// The A/B test tab: versions with their own subject (and optionally their own words), and how
/// often each is sent.
struct MktCampABSections: View {
    @Bindable var model: MktCampDetailModel
    @Environment(SessionStore.self) private var session

    private var canEdit: Bool {
        model.status.isABEditable && session.permissions.can(.update, moduleName: Marketing.RBAC.campaigns)
    }

    var body: some View {
        if !model.status.isABEditable {
            Section {
                Label("A/B settings can only change while the campaign is a draft or checked. Make a copy to test a "
                      + "new idea.", systemImage: "lock")
                    .foregroundStyle(Tone.warning.textColor)
            }
        }
        Section {
            Toggle(isOn: $model.ab.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test different versions")
                    Text("Each person always gets the same version (chosen from who they are), so a resend or a resume "
                         + "never mixes them up. Weights set the split.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityIdentifier("mkt.ab.enabled")
        } header: {
            Text("A/B test")
        }
        .disabled(!canEdit)
        ForEach($model.ab.variants) { $variant in
            variantSection($variant)
        }
        if canEdit {
            Section {
                Button {
                    model.ab.variants.append(MktCampVariant(key: model.ab.nextKey))
                } label: {
                    Label("Add a version", systemImage: "plus")
                }
                .disabled(model.ab.variants.count >= MktCampAB.maxVariants)
                .accessibilityIdentifier("mkt.ab.add")
                Button { Task { await model.saveAB() } } label: {
                    HStack {
                        Label("Save A/B test", systemImage: "square.and.arrow.down")
                        if model.busy == "A/B" { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isBusy || !model.abDirty)
                .accessibilityIdentifier("mkt.ab.save")
            } footer: {
                Text("Results and the winning version appear on the Results tab once it’s sending. Up to "
                     + "\(MktCampAB.maxVariants) versions.")
            }
        }
    }

    private func variantSection(_ variant: Binding<MktCampVariant>) -> some View {
        let share = model.ab.share(of: variant.wrappedValue)
        return Section {
            LabeledContent("Name") {
                TextField("A", text: Binding(get: { variant.wrappedValue.key },
                                             set: { variant.wrappedValue.key = String($0.prefix(16)) }))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("mkt.ab.key")
            }
            TextField(model.campaign?.subject.trimmedOrNil ?? "Subject line", text: variant.subject, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityIdentifier("mkt.ab.subject")
            LabeledContent("Weight") {
                TextField("1", text: variant.weight)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("mkt.ab.weight")
            }
            Text("About \(share.formatted(.number.precision(.fractionLength(0))))% of sends")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            Toggle("Its own words", isOn: variant.overridesBody)
                .accessibilityIdentifier("mkt.ab.override")
            if variant.wrappedValue.overridesBody {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Email (HTML)").font(.wsCaption).foregroundStyle(.secondaryText)
                    TextEditor(text: variant.bodyHTML)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("mkt.ab.html")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plain-text version").font(.wsCaption).foregroundStyle(.secondaryText)
                    TextEditor(text: variant.bodyText)
                        .frame(minHeight: 100)
                        .accessibilityIdentifier("mkt.ab.text")
                }
                if variant.wrappedValue.bodyHTML.trimmedOrNil != nil {
                    RichTextView(html: MktEmailSample.fill(variant.wrappedValue.bodyHTML), appearance: .email, linksOpen: false)
                }
            }
            if canEdit {
                Button(role: .destructive) {
                    model.ab.variants.removeAll { $0.id == variant.wrappedValue.id }
                } label: {
                    Label("Remove this version", systemImage: "trash")
                }
                .disabled(model.ab.variants.count <= 2)
                .accessibilityIdentifier("mkt.ab.remove")
            }
        } header: {
            Text("Version \(variant.wrappedValue.key.trimmedOrNil ?? "?")")
        } footer: {
            Text("Without its own words, this version uses the email’s main words.")
        }
        .disabled(!canEdit)
    }
}
