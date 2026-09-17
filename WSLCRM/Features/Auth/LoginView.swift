import SwiftUI

struct LoginView: View {
    @Environment(SessionStore.self) private var session
    @State private var identifier = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @State private var showingForgotPassword = false
    @FocusState private var focused: Field?

    private enum Field { case identifier, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email or username").font(.subheadline.weight(.semibold))
                        TextField("name@company.co.uk", text: $identifier)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focused, equals: .identifier)
                            .onSubmit { focused = .password }
                            .fieldStyle()
                            .accessibilityIdentifier("login.identifier")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password").font(.subheadline.weight(.semibold))
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focused, equals: .password)
                            .onSubmit(submit)
                            .fieldStyle()
                            .accessibilityIdentifier("login.password")
                    }
                }

                if let error {
                    InlineErrorRow(error: error)
                        .accessibilityIdentifier("login.error")
                }

                Button(action: submit) {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Sign in")
                    }
                }
                .buttonStyle(.large())
                .disabled(!canSubmit)
                .accessibilityIdentifier("login.submit")

                Button("Forgot password?") { showingForgotPassword = true }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView(prefill: identifier.contains("@") ? identifier : "")
        }
        .onAppear { focused = identifier.isEmpty ? .identifier : .password }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandMark(size: 56)
            Text(Brand.current.name)
                .font(.largeTitle.bold())
                .accessibilityIdentifier("login.brandName")
            Text("Sign in to your \(Brand.current.name) account")
                .font(.title3)
                .foregroundStyle(.secondaryText)
            if session.environmentName != "Production" {
                StatusBadge(text: "\(session.environmentName) environment", systemImage: "hammer", tone: .warning)
            }
        }
        .padding(.top, 32)
    }

    private var canSubmit: Bool {
        !isSubmitting && !identifier.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await session.signIn(identifier: identifier.trimmingCharacters(in: .whitespaces), password: password)
                password = ""
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

struct TwoFactorView: View {
    @Environment(SessionStore.self) private var session
    let challenge: TwoFactorChallenge
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @State private var resendAvailableAt = Date().addingTimeInterval(30)
    @State private var resendMessage: String?
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Check your email")
                        .font(.largeTitle.bold())
                    Text("Enter the 6-digit code we sent to \(challenge.email ?? "your email address").")
                        .font(.title3)
                        .foregroundStyle(.secondaryText)
                }
                .padding(.top, 32)

                TextField("123456", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($codeFocused)
                    .fieldStyle()
                    .accessibilityLabel("Verification code")
                    .accessibilityIdentifier("twofactor.code")
                    .onChange(of: code) { _, newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue { code = digits }
                        if digits.count == 6 { submit() }
                    }

                if let error {
                    InlineErrorRow(error: error)
                }
                if let resendMessage {
                    Label(resendMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                }

                Button(action: submit) {
                    if isSubmitting { ProgressView().tint(.white) } else { Text("Verify") }
                }
                .buttonStyle(.large())
                .disabled(code.count != 6 || isSubmitting)
                .accessibilityIdentifier("twofactor.submit")

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                    Button(remaining > 0 ? "Resend code in \(remaining)s" : "Resend code") {
                        resend()
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(remaining > 0)
                }

                Button("Use a different account", role: .cancel) {
                    session.cancelTwoFactor()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { codeFocused = true }
    }

    private func submit() {
        guard code.count == 6, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await session.verifyTwoFactor(code: code)
            } catch {
                self.error = error.asAPIError
                code = ""
            }
        }
    }

    private func resend() {
        resendMessage = nil
        error = nil
        resendAvailableAt = Date().addingTimeInterval(30)
        Task {
            do {
                try await session.resendTwoFactorCode()
                resendMessage = "A new code is on its way."
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

struct ForgotPasswordView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var prefill: String
    @State private var isSubmitting = false
    @State private var sent = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        Label("If an account exists for \(prefill), you'll receive an email with a reset link.",
                              systemImage: "envelope.open.fill")
                    }
                } else {
                    Section {
                        TextField("Email address", text: $prefill)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("We'll email you a link to reset your password.")
                    }
                    if let error {
                        Section { InlineErrorRow(error: error) }
                    }
                    Section {
                        Button {
                            submit()
                        } label: {
                            if isSubmitting { ProgressView() } else { Text("Send reset link") }
                        }
                        .disabled(!prefill.contains("@") || isSubmitting)
                    }
                }
            }
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await session.requestPasswordReset(email: prefill.trimmingCharacters(in: .whitespaces))
                sent = true
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.title3)
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator)))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }
}
