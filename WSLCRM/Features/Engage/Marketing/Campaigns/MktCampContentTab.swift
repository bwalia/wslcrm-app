import SwiftUI

/// The Content tab: a ready-made design, the subject, the email itself (the native editor or its
/// HTML), the inbox preview line, the sender, the plain-text version, personalisation, details,
/// and a live preview drawn natively as "Alex" would see it.
struct MktCampContentSections: View {
    @Bindable var model: MktCampDetailModel
    @Environment(SessionStore.self) private var session

    private var canEdit: Bool { model.editable && session.permissions.can(.update, moduleName: Marketing.RBAC.campaigns) }
    private var canUpload: Bool { session.permissions.can(.create, moduleName: Marketing.RBAC.templates) }
    private var isEmail: Bool { model.campaign?.isEmail ?? true }

    var body: some View {
        lockedNotice
        if canEdit {
            Section {
                Button { model.sheet = .gallery } label: {
                    Label("Choose a ready-made design", systemImage: "paintpalette")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("mkt.content.gallery")
            } footer: {
                Text("Welcome, newsletter, special offer, event invitation and more — then change the words.")
            }
        }
        if isEmail {
            subjectSection
            emailSection
            moreOptions
        } else {
            smsSection
        }
        personaliseSection
        saveSection
        detailsSection
        previewSection
    }

    // MARK: Pieces

    @ViewBuilder
    private var lockedNotice: some View {
        if !model.editable {
            Section {
                Label(model.status == .completed || model.status == .cancelled
                      ? "This email has been sent, so it can’t be changed. To send something similar, use More → Make a copy."
                      : "This email is being sent, so it can’t be changed right now. Pause it to make changes (then "
                        + "press “Check it” again), or use More → Make a copy.",
                      systemImage: "lock")
                    .foregroundStyle(Tone.warning.textColor)
            }
        } else if model.status != .draft {
            Section {
                Label("If you change and save the email, press “Check it” again before sending.", systemImage: "info.circle")
                    .foregroundStyle(Tone.info.textColor)
            }
        }
    }

    private var subjectSection: some View {
        Section {
            TextField("The line people see in their inbox", text: $model.content.subject, axis: .vertical)
                .lineLimit(1...3)
                .disabled(!canEdit)
                .accessibilityIdentifier("mkt.content.subject")
            if canEdit {
                Button { model.insert("{{contact.first_name}}", into: "subject") } label: {
                    Label("Add their first name", systemImage: "person.text.rectangle")
                }
                .accessibilityIdentifier("mkt.content.subject.firstName")
            }
        } header: {
            Text("Subject")
        } footer: {
            if model.content.subject.count > 60 {
                Text("Subjects over about 60 characters are often cut off on phones.")
                    .foregroundStyle(Tone.warning.textColor)
            }
        }
    }

    private var emailSection: some View {
        Section {
            Picker("How to edit", selection: Binding(get: { model.easyEditor }, set: { easy in
                if easy && model.content.madeWithCode { model.confirm = .easyEditor } else { model.easyEditor = easy }
            })) {
                Text("Easy editor").tag(true)
                Text("HTML code").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mkt.content.mode")
            if model.easyEditor {
                Button { model.sheet = .editor } label: {
                    Label(canEdit ? "Open the email editor" : "Open the email", systemImage: "square.and.pencil")
                        .font(.wsHeadline)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("mkt.content.openEditor")
                Text("Change the words, pictures and buttons block by block. Personalise with each person’s name. "
                     + "The unsubscribe link and your address are added for you.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            } else {
                TextEditor(text: $model.content.bodyHTML)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 220)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(!canEdit)
                    .accessibilityIdentifier("mkt.content.html")
                if canEdit && canUpload {
                    Button { model.pickingImageFile = true } label: {
                        HStack {
                            Label(model.uploadingImage ? "Uploading picture…" : "Add a picture", systemImage: "photo.badge.plus")
                            if model.uploadingImage { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.uploadingImage)
                    .accessibilityIdentifier("mkt.content.uploadImage")
                }
            }
        } header: {
            Text("Your email")
        }
    }

    @ViewBuilder
    private var moreOptions: some View {
        let hint = MktCampContent.previewTextHint(model.content.previewText.count)
        Section {
            TextField("A line under the subject in the inbox", text: $model.content.previewText, axis: .vertical)
                .lineLimit(1...3)
                .disabled(!canEdit)
                .accessibilityIdentifier("mkt.content.previewText")
            Label("\(model.content.previewText.count) characters. \(hint.text)",
                  systemImage: hint.good ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.wsFootnote)
                .foregroundStyle(hint.good ? Tone.success.textColor : Tone.warning.textColor)
        } header: {
            Text("Inbox preview line (optional)")
        }
        Section {
            LabeledContent("From name") {
                TextField("Your business", text: $model.content.fromName).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("mkt.content.fromName")
            }
            LabeledContent("From email") {
                TextField("The usual sender", text: $model.content.fromEmail).multilineTextAlignment(.trailing)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.content.fromEmail")
            }
            LabeledContent("Replies go to") {
                TextField("Optional", text: $model.content.replyTo).multilineTextAlignment(.trailing)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.content.replyTo")
            }
        } header: {
            Text("Sender (optional)")
        }
        .disabled(!canEdit)
        Section {
            TextEditor(text: $model.content.bodyText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 120)
                .disabled(!canEdit)
                .accessibilityIdentifier("mkt.content.text")
        } header: {
            Text("Plain-text version (optional)")
        } footer: {
            Text("Shown by email apps that block pictures and design; it also helps your emails reach the inbox.")
        }
    }

    private var smsSection: some View {
        Section {
            TextEditor(text: $model.content.bodyText)
                .frame(minHeight: 140)
                .disabled(!canEdit)
                .accessibilityIdentifier("mkt.content.sms")
        } header: {
            Text("Message")
        } footer: {
            Text("\(model.content.bodyText.count) characters. Texts over 160 characters are sent as more than one message.")
        }
    }

    @ViewBuilder
    private var personaliseSection: some View {
        if canEdit {
            Section {
                Picker("Put it in", selection: $model.insertTarget) {
                    if isEmail { Text("Subject").tag("subject") }
                    if isEmail { Text("Email (HTML)").tag("body_html") }
                    Text(isEmail ? "Plain-text version" : "Message").tag("body_text")
                }
                .accessibilityIdentifier("mkt.content.insertTarget")
                Menu {
                    ForEach(model.mergeFields) { field in
                        Button("\(field.label) — \(field.token)") {
                            model.insert(field.token, into: isEmail ? model.insertTarget : "body_text")
                        }
                    }
                } label: {
                    Label("Add a personal detail", systemImage: "curlybraces")
                }
                .disabled(model.mergeFields.isEmpty)
                .accessibilityIdentifier("mkt.content.mergeField")
            } header: {
                Text("Personalise")
            } footer: {
                Text("Adds it at the end of the chosen part; move it where you want. {{unsubscribe_url}} works too — "
                     + "if your email has no unsubscribe link, one is added for you.")
            }
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        if canEdit {
            Section {
                Button { Task { await model.saveContent() } } label: {
                    HStack {
                        Label("Save content", systemImage: "square.and.arrow.down")
                        Spacer()
                        if model.busy == "Save" { ProgressView() }
                    }
                }
                .disabled(!model.contentDirty || model.isBusy)
                .accessibilityIdentifier("mkt.content.save")
            } footer: {
                Text(model.contentDirty ? "You have changes that aren’t saved yet." : "Everything is saved.")
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        if canEdit {
            Section {
                TextField("What it’s for (only you see this)", text: $model.objective, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("mkt.details.objective")
                Picker("Kind of message", selection: $model.messageType) {
                    ForEach(MktCamp.messageTypes) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("mkt.details.type")
                Picker("Send by", selection: $model.channel) {
                    ForEach(MktCamp.channels) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("mkt.details.channel")
                Toggle("Someone must approve it before it’s sent", isOn: $model.approvalRequired)
                    .accessibilityIdentifier("mkt.details.approval")
                Button { Task { await model.saveDetails() } } label: { Label("Save details", systemImage: "checkmark") }
                    .disabled(!model.detailsDirty || model.isBusy)
                    .accessibilityIdentifier("mkt.details.save")
            } header: {
                Text("Details")
            } footer: {
                Text("Service messages (an order update, a reminder) skip permission and quiet hours, so only workspace "
                     + "admins can send them. Changing how it’s sent, its kind or approval sends it back to draft.")
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        let rendered = model.rendered
        Section {
            if let error = model.previewError { InlineErrorRow(error: error) }
            if isEmail {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rendered?.subject?.trimmedOrNil ?? model.content.subject.trimmedOrNil ?? "(no subject)")
                        .font(.wsHeadline).lineLimit(2)
                    Text("\(model.content.fromName.trimmedOrNil ?? "The usual sender") — "
                         + (model.content.previewText.trimmedOrNil ?? "No preview line"))
                        .font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
                }
                Picker("Width", selection: $model.phoneWidthPreview) {
                    Text("Full width").tag(false)
                    Text("Phone width").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("mkt.content.previewWidth")
                RichTextView(html: rendered?.html ?? MktEmailSample.fill(model.content.bodyHTML), appearance: .email,
                             linksOpen: false)
                    .frame(maxWidth: model.phoneWidthPreview ? 375 : .infinity)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("mkt.content.preview")
                if !model.content.hasUnsubscribeLink {
                    Text("No {{unsubscribe_url}} found — an unsubscribe footer is added when it’s sent.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            } else {
                Text(rendered?.text ?? model.content.bodyText).font(.wsBody)
                    .accessibilityIdentifier("mkt.content.preview")
            }
            if let warnings = rendered?.warnings, !warnings.isEmpty {
                Label("Things to look at: " + warnings.map(MktCamp.warningText).joined(separator: ", "),
                      systemImage: "exclamationmark.triangle")
                    .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
            }
        } header: {
            Text("Live preview (for a sample person, “Alex”)")
        }
    }
}
