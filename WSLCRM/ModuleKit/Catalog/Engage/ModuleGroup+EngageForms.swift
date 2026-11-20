import SwiftUI

/// Forms — the form builder, sharing, responses and insights (`/api/v2/forms`, RBAC module `forms`).
///
/// Hand-built screens (a form builder can't be described as a list): `forms.home` (every form),
/// `forms.form:<uuid>` (one form's editor: Build · Settings · Share · Responses · Insights) and
/// `forms.response:<form uuid>/<response uuid>` (one response).
extension ModuleGroup {
    static let engageForms = ModuleGroup(
        id: "engage.forms",
        screens: ["forms": WebFormScreens.home],
        screen: { id in
            let parts = EngageArea.parts(id)
            switch (parts.screen, parts.argument) {
            case (WebFormScreens.home, nil):
                return AnyView(WebFormsHomeView())
            case (WebFormScreens.form, let uuid?):
                return AnyView(WebFormEditorView(uuid: uuid))
            case (WebFormScreens.response, let argument?):
                let ids = argument.split(separator: "/").map(String.init)
                guard ids.count == 2 else { return nil }
                return AnyView(WebFormResponseScreen(formUUID: ids[0], responseUUID: ids[1]))
            default:
                return nil
            }
        })
}

/// The Forms part's screen ids, so other screens (a customer's page, a notification) can open them.
enum WebFormScreens {
    static let home = "forms.home"
    /// One form: `EngageArea.route(WebFormScreens.form, uuid)`.
    static let form = "forms.form"
    /// One response: `EngageArea.route(WebFormScreens.response, "\(formUUID)/\(responseUUID)")`.
    static let response = "forms.response"
}

/// One response opened on its own (loads its form first).
struct WebFormResponseScreen: View {
    let formUUID: String
    let responseUUID: String
    @Environment(\.services) private var services
    @State private var form: WebFormDetail?
    @State private var error: APIError?

    var body: some View {
        Group {
            if let form {
                WebFormResponseDetailView(form: form, submissionID: responseUUID)
            } else if let error {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                SkeletonList()
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { form = try await services.webForms.form(formUUID) } catch { self.error = error.asAPIError }
    }
}
