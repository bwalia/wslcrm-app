import SwiftUI

/// "Fill it in now": the live form, filled in natively and sent as a real response (the same public API
/// visitors use: files are stored as they're picked, then the answers are sent once).
struct WebFormLiveFillView: View {
    let publicID: String
    let title: String
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<WebFormPublic> = .idle
    @State private var answers: [String: JSONValue] = [:]
    @State private var errors: [String: String] = [:]
    @State private var formError: String?
    @State private var submitting = false
    @State private var thanks: String?
    @State private var startedAt = Date()
    @State private var idempotencyKey = UUID().uuidString

    var body: some View {
        Group {
            switch state {
            case .loaded(let form):
                if let thanks {
                    ContentUnavailableView {
                        Label("Sent", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text(thanks)
                    } actions: {
                        Button("Fill it in again") { restart() }.buttonStyle(.bordered)
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                } else if form.needsCaptcha {
                    ContentUnavailableView {
                        Label("This form has the “I’m human” check", systemImage: "checkmark.shield")
                    } description: {
                        Text("That check is Cloudflare’s and only works where the form is published, so the app can’t "
                             + "send this form. Share the link instead, or turn the check off in the form’s Settings "
                             + "to fill it in here.")
                    }
                } else {
                    WebFormRunnerView(fields: form.fields, answers: $answers, errors: $errors,
                                      submitLabel: form.submitLabel ?? "Submit", submitting: submitting,
                                      formError: formError, upload: { field, file in
                                          try await upload(form, field, file)
                                      }, header: AnyView(intro(form))) { visible in
                        Task { await submit(form, visible) }
                    }
                }
            case .failed(let error):
                closedOrError(error)
            default:
                SkeletonList()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await load() }
        .interactiveDismissDisabled(submitting || !answers.isEmpty && thanks == nil)
    }

    private func intro(_ form: WebFormPublic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(form.title).font(.wsTitle3.bold())
            if let description = form.description {
                RichTextView(.auto(description))
            }
            Label("This sends a real response, as a visitor would.", systemImage: "info.circle")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private func closedOrError(_ error: APIError) -> some View {
        let server = error.serverError
        if server?.status == 410 || server?.code == "form_closed" || server?.code == "form_full" {
            ContentUnavailableView("Not taking responses", systemImage: "lock",
                                   description: Text(server?.message ?? "This form is no longer accepting responses."))
        } else if server?.status == 404 {
            ContentUnavailableView("This form isn’t available", systemImage: "questionmark.square.dashed",
                                   description: Text("Publish it first, or check it hasn’t been deleted."))
        } else {
            ErrorStateView(error: error) { Task { await load() } }
        }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await services.webForms.publicForm(publicID))
            startedAt = Date()
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func restart() {
        answers = [:]
        errors = [:]
        formError = nil
        thanks = nil
        idempotencyKey = UUID().uuidString
        Task { await load() }
    }

    private func upload(_ form: WebFormPublic, _ field: WebFormField, _ file: EngageFile) async throws -> WebFormFileAnswer {
        guard let key = field.key else { throw ResourceService.problem(422, "This question can’t take files.") }
        return try await services.webForms.upload(publicID: publicID, field: key, file: file, renderToken: form.renderToken)
    }

    private func submit(_ form: WebFormPublic, _ visible: [String: JSONValue]) async {
        submitting = true
        formError = nil
        defer { submitting = false }
        // Files are sent as their stored ids.
        var body = visible
        for field in form.fields where field.type == .fileUpload {
            guard let key = field.key, let files = body[key]?.arrayValue else { continue }
            body[key] = .array(files.compactMap { $0["id"] })
        }
        do {
            thanks = try await services.webForms.submit(
                publicID: publicID,
                body: WebFormsAPI.submitBody(answers: body, renderToken: form.renderToken, startedAt: startedAt),
                idempotencyKey: idempotencyKey)
        } catch {
            let apiError = error.asAPIError
            if let server = apiError.serverError, !server.fieldErrors.isEmpty {
                errors = server.fieldErrors
                formError = server.message
            } else {
                formError = apiError.localizedDescription
            }
        }
    }
}
