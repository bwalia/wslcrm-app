import SwiftUI

struct LoginView: View {
    @Environment(SessionStore.self) private var session
    @Environment(APIEndpointController.self) private var endpoint
    @State private var identifier = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: APIError?
    @State private var showingForgotPassword = false
    @State private var showingEndpoint = false
    @FocusState private var focused: Field?

    private enum Field { case identifier, password }

    /// Accounts are made by invitation (there's no sign-up in the app or on the dashboard): say how to get one.
    static let newHereAdvice = "You need an invitation to sign in. Ask your employer, or whoever runs your company's "
        + "workspace, to invite your email address. Their email has a link to set up your account; then sign in here."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 20) {
                    Text("Sign in")
                        .font(.brandTitle)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email or username").font(.brandCaption).foregroundStyle(.secondaryText)
                        TextField(text: $identifier, prompt: Text(verbatim: "name@company.co.uk")) { Text("Email or username") }
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
                        Text("Password").font(.brandCaption).foregroundStyle(.secondaryText)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focused, equals: .password)
                            .onSubmit(submit)
                            .fieldStyle()
                            .accessibilityIdentifier("login.password")
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
                        .font(.brandCallout)
                        .frame(maxWidth: .infinity, minHeight: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("New here?").font(.brandHeadline)
                        Text(LoginView.newHereAdvice)
                            .font(.brandFootnote)
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("login.newHere")
                }
                .brandCard(padding: 22, radius: 26)
                .padding(.horizontal, 16)
                // Overlaps the hero's foot through layout (not .offset), so taps land on the fields.
                .padding(.top, -28)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .brandCanvas()
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView(prefill: identifier.contains("@") ? identifier : "")
        }
        .sheet(isPresented: $showingEndpoint) {
            APIEndpointSheet()
        }
        .onAppear { focused = identifier.isEmpty ? .identifier : .password }
    }

    /// The brand moment: the website's dark navy with an accent glow, the mark and the name in
    /// the display face. The form sits on a card that overlaps its foot.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                BrandMark(size: 48)
                    .padding(8)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer(minLength: 12)
                // Pointing the app at another server is for testers: the App Store build hides it
                // (unless it was already repointed, so there's a way back).
                if endpoint.buildName != "Production" || endpoint.isOverridden {
                    Button {
                        showingEndpoint = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.wsTitle3)
                            .foregroundStyle(Palette.onDarkInk)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Environment settings")
                    .accessibilityIdentifier("login.environmentSettings")
                }
            }
            Text(BrandStore.shared.brand.name)
                .font(.brandDisplay)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("login.brandName")
            Text("Your whole business, in your pocket.")
                .font(.brandCallout)
                .foregroundStyle(Palette.onDarkMuted)
            if session.environmentName != "Production" {
                Pill(text: "\(session.environmentName) environment", systemImage: "hammer",
                     foreground: Palette.onDarkInk, background: .white.opacity(0.14))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Palette.heroGradient
                RadialGradient(colors: [Color.accentColor.opacity(0.6), .clear], center: .topTrailing,
                               startRadius: 10, endRadius: 320)
                RadialGradient(colors: [Palette.tileColors[1].opacity(0.35), .clear], center: .bottomLeading,
                               startRadius: 10, endRadius: 260)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .environment(\.colorScheme, .dark)
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
                        .font(.brandDisplay)
                    Text("Enter the 6-digit code we sent to \(challenge.email ?? "your email address").")
                        .font(.brandBody)
                        .foregroundStyle(.secondaryText)
                }
                .padding(.top, 32)

                TextField("123456", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(BrandFont.font(.monoMedium, size: 34, relativeTo: .largeTitle))
                    .tracking(8)
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
                    .font(.wsBody.weight(.semibold))
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
        .brandCanvas()
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
    /// The link opens the reset page in the phone's browser, not in the app: say so, and to come back.
    static let afterSending = "Open the link from the email on this phone: it opens in your browser, where you "
        + "choose a new password. Then come back here and sign in with it."

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
                    } footer: {
                        Text(ForgotPasswordView.afterSending)
                    }
                } else {
                    Section {
                        TextField("Email address", text: $prefill)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("We'll email you a link to reset your password. " + ForgotPasswordView.afterSending)
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
            .font(BrandFont.font(.regular, size: 17, relativeTo: .body))
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }
}
