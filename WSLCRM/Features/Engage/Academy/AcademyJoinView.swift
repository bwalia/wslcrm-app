import SwiftUI

/// Become an instructor: anyone signed in may join the academy as one (a role in the academy's
/// own workspace). Shown to people who can't open courses yet, as the web does.
struct AcademyJoinView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<AcademyInstructorStatus> = .idle
    @State private var registering = false
    @State private var notice: EngageNotice?

    private static let benefits: [(String, String, String)] = [
        ("book", "Publish your own courses", "Create courses and lessons with text, pictures and videos. You manage only what you own."),
        ("sterlingsign.circle", "Earn from every sale", "Set your price. The platform takes its fee and pays the rest into your bank."),
        ("graduationcap", "Reach every learner", "Your published courses appear in the academy alongside everyone else’s."),
    ]

    var body: some View {
        List {
            switch state {
            case .loaded(let status):
                content(status)
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                EmptyView()
            }
            Section {
                NavigationLink { AcademyLearningView() } label: {
                    Label("My learning", systemImage: "graduationcap")
                }
                .accessibilityIdentifier("academy.join.learning")
            } footer: {
                Text("Courses you’re taking, and courses you can join.")
            }
        }
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .navigationTitle("Academy")
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ status: AcademyInstructorStatus) -> some View {
        let isInstructor = status.isInstructor || status.isOwner
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Tone.brand.textColor)
                    .accessibilityHidden(true)
                Text(isInstructor ? "You’re an instructor" : "Teach on the academy")
                    .font(.wsTitle2).accessibilityAddTraits(.isHeader)
                Text(isInstructor ? "Open the academy workspace to create and manage your courses."
                                  : "Share what you know, build your audience and earn from your courses.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 6)
        }
        if isInstructor {
            Section {
                Label(status.isOwner ? "You own the academy workspace" : "Instructor access is on",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success.textColor)
                if let namespace = status.namespace {
                    if session.workspace?.uuid == namespace.uuid {
                        Text("You’re in the academy workspace. If your courses don’t show, pull down to refresh, "
                            + "or ask the academy’s owner to check your role.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    } else {
                        Button { Task { await open(namespace) } } label: {
                            Label("Open the academy workspace", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.large(.brand))
                        .accessibilityIdentifier("academy.join.open")
                    }
                }
            }
        } else {
            Section("Why teach") {
                ForEach(Self.benefits, id: \.1) { benefit in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(benefit.1).font(.wsHeadline)
                            Text(benefit.2).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                    } icon: {
                        Image(systemName: benefit.0).foregroundStyle(Tone.brand.textColor)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Button { Task { await register() } } label: {
                    Label(registering ? "Setting you up…" : "Become an instructor", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.large(.brand))
                .disabled(registering)
                .accessibilityIdentifier("academy.join.register")
            } footer: {
                Text("You can add your bank details for payments later, in Earnings and payments.")
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.academy.instructorStatus())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func register() async {
        registering = true
        defer { registering = false }
        do {
            let status = try await services.academy.registerInstructor()
            state = .loaded(AcademyInstructorStatus(isInstructor: true, isOwner: status.isOwner, namespace: status.namespace))
            notice = .done("You’re now an instructor.")
            if let namespace = status.namespace { await open(namespace) }
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    /// Switches to the academy workspace so the new instructor permissions load.
    private func open(_ namespace: AcademyNamespace) async {
        let workspace = session.workspaces.first { $0.uuid == namespace.uuid }
            ?? Workspace(uuid: namespace.uuid, internalId: namespace.id, name: namespace.name, slug: namespace.slug)
        await session.select(workspace)
        notice = .done("You’re now in the \(namespace.name) workspace.")
    }
}
