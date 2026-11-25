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

    static let staysSignedIn = MacSupport.isMac ? "You stay signed in on this Mac until you sign out."
        : "You stay signed in on this phone until you sign out."

    /// Accounts are made by invitation (there's no sign-up in the app or on the dashboard): say how to get one.
    static let newHereAdvice = "You need an invitation to sign in. Ask your employer, or whoever runs your company's "
        + "workspace, to invite your email address. Their email has a link to set up your account; then sign in here."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AuthHero(subtitle: MacSupport.isMac ? "Your whole business, in one place." : "Your whole business, in your pocket.",
                         showsEnvironment: endpoint.buildName != "Production" || endpoint.isOverridden) {
                    showingEndpoint = true
                }

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
                    .buttonStyle(.large(fill: true))
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("login.submit")

                    // The session is kept in the Keychain and renewed each time the app is used (the server's
                    // refresh token lasts 30 days from the last use), so there is no "remember me" to tick.
                    Label(LoginView.staysSignedIn, systemImage: "lock.shield")
                        .font(.brandFootnote)
                        .foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("login.staysSignedIn")

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
            VStack(alignment: .leading, spacing: 0) {
                AuthHero(subtitle: "One more step, so it’s really you.", showsEnvironment: false) {}

                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 48, height: 48)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check your email")
                                .font(.brandTitle)
                                .accessibilityAddTraits(.isHeader)
                            Text(sentTo)
                                .font(.brandCallout)
                                .foregroundStyle(.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    OneTimeCodeField(code: $code, focused: $codeFocused, hasError: error != nil)
                        .onChange(of: code) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(6))
                            if digits != newValue { code = digits }
                            if !digits.isEmpty { error = nil }
                            if digits.count == 6 { submit() }
                        }

                    if let error {
                        InlineErrorRow(error: error)
                    }
                    if let resendMessage {
                        Label(resendMessage, systemImage: "checkmark.circle.fill")
                            .font(.brandCallout)
                            .foregroundStyle(Tone.success.textColor)
                    }

                    Button(action: submit) {
                        if isSubmitting { ProgressView().tint(.white) } else { Text("Verify and sign in") }
                    }
                    .buttonStyle(.large(fill: true))
                    .disabled(code.count != 6 || isSubmitting)
                    .accessibilityIdentifier("twofactor.submit")

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                        HStack(spacing: 6) {
                            Text("Didn’t get it?").foregroundStyle(.secondaryText)
                            if remaining > 0 {
                                Text("You can send another in \(remaining)s")
                                    .foregroundStyle(.secondaryText)
                                    .monospacedDigit()
                            } else {
                                Button("Send a new code") { resend() }
                                    .fontWeight(.semibold)
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("twofactor.resend")
                            }
                        }
                        .font(.brandCallout)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }

                    Divider()

                    Button(role: .cancel) {
                        session.cancelTwoFactor()
                    } label: {
                        Label("Use a different account", systemImage: "arrow.uturn.backward")
                            .font(.brandCallout.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("twofactor.differentAccount")
                }
                .brandCard(padding: 22, radius: 26)
                .padding(.horizontal, 16)
                .padding(.top, -28)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .brandCanvas()
        .onAppear { codeFocused = true }
    }

    private var sentTo: AttributedString {
        var text = AttributedString("Enter the 6-digit code we sent to ")
        var email = AttributedString(challenge.email ?? "your email address")
        email.font = .brandCallout.weight(.semibold)
        email.foregroundColor = Color(.label)
        text.append(email)
        text.append(AttributedString(". It only works once."))
        return text
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

/// The brand moment at the top of the sign-in screens: the website's dark navy with an accent glow, the mark
/// and the name in the display face. The form sits on a card that overlaps its foot.
struct AuthHero: View {
    let subtitle: String
    /// The gear for pointing the app at another server (testers; the App Store build hides it).
    var showsEnvironment: Bool
    var onEnvironment: () -> Void
    @Environment(SessionStore.self) private var session

    init(subtitle: String, showsEnvironment: Bool, onEnvironment: @escaping () -> Void) {
        self.subtitle = subtitle
        self.showsEnvironment = showsEnvironment
        self.onEnvironment = onEnvironment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                BrandMark(size: 48)
                    .padding(8)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer(minLength: 12)
                if showsEnvironment {
                    Button(action: onEnvironment) {
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
            Text(subtitle)
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
}

/// A one-time code as six boxes. Underneath is ONE real text field (invisible text), so the code can be
/// typed, pasted or filled in from Mail/Messages (`.oneTimeCode`), and the UI tests type into
/// `twofactor.code` as before. The box for the next digit is highlighted; after a wrong code the boxes
/// turn red until the person types again.
struct OneTimeCodeField: View {
    @Binding var code: String
    var focused: FocusState<Bool>.Binding
    var hasError = false
    var length = 6

    private var boxHeight: CGFloat { MacSupport.isMac ? 58 : 64 }

    var body: some View {
        ZStack {
            HStack(spacing: MacSupport.isMac ? 10 : 8) {
                ForEach(0..<length, id: \.self) { index in box(index) }
            }
            .accessibilityHidden(true)
            TextField("", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused(focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Verification code")
                .accessibilityValue(code.isEmpty ? "Empty" : code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("twofactor.code")
        }
        .frame(height: boxHeight)
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }

    private func box(_ index: Int) -> some View {
        let digits = Array(code)
        let digit = index < digits.count ? String(digits[index]) : nil
        let isNext = focused.wrappedValue && index == min(digits.count, length - 1) && !(digits.count == length && index < length - 1)
        let stroke: Color = hasError ? Tone.danger.solidColor : (isNext ? .accentColor : Palette.hairline)
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.canvas)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(stroke, lineWidth: isNext || hasError ? 2 : 1)
            if let digit {
                Text(digit)
                    .font(BrandFont.font(.monoMedium, size: MacSupport.isMac ? 26 : 30, relativeTo: .title))
                    .foregroundStyle(Color(.label))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if isNext {
                // A caret where the next digit goes.
                TimelineView(.periodic(from: .now, by: 0.55)) { context in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2, height: boxHeight * 0.42)
                        .opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0 ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: 64)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.18), value: digit)
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
