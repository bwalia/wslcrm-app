import AVKit
import SwiftUI

/// A lesson's content drawn natively: text, lists, pictures and tables by `RichTextView`, and each
/// YouTube or Vimeo video as a row that opens it in its own app (those players are web pages, so
/// they can't play inside this app).
struct AcademyLessonContentView: View {
    let html: String
    var linksOpen = true

    var body: some View {
        let blocks = AcademyContent.parse(html).blocks
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                if case .video(let src) = block.kind {
                    AcademyVideoRow(embed: src, opens: linksOpen)
                } else {
                    RichTextView(html: block.html, linksOpen: linksOpen)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A YouTube or Vimeo video in a lesson.
struct AcademyVideoRow: View {
    let embed: String
    var opens = true

    var body: some View {
        let provider = AcademyVideo.provider(embed)
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(provider == "YouTube" ? Color.red : Color.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(provider) video").font(.wsSubheadline.weight(.semibold))
                Text(opens ? "Opens in the \(provider) app." : (AcademyVideo.watchURL(embed)?.absoluteString ?? embed))
                    .font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            if opens, let url = AcademyVideo.watchURL(embed) {
                Link(destination: url) { Text("Watch").font(.wsSubheadline.weight(.semibold)) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Watch the \(provider) video")
                    .accessibilityIdentifier("academy.video.watch")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A lesson as a learner sees it: its video (played natively), length and content.
/// Used to preview a lesson while writing a course, and to study one.
struct AcademyLessonReaderView: View {
    let lesson: AcademyLesson
    /// The academy workspace's slug, to fetch the video's address. nil: no video player.
    var namespaceSlug: String?
    /// Learner progress, when studying a course you can open.
    var completed: Bool?
    var onToggleComplete: ((Bool) async -> Bool)?
    var nextLesson: AcademyLesson?
    var openNext: ((AcademyLesson) -> Void)?
    @Environment(\.services) private var services
    @State private var player: AVPlayer?
    @State private var loadingVideo = false
    @State private var videoError: APIError?
    @State private var done: Bool?
    @State private var working = false
    @State private var notice: EngageNotice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if lesson.hasVideo { video }
                if let html = lesson.contentHtml, html.trimmedOrNil != nil {
                    AcademyLessonContentView(html: html)
                } else if lesson.contentHtml == nil, !lesson.isPreview, onToggleComplete == nil, namespaceSlug != nil {
                    Label("This lesson’s content is for people who have joined the course.", systemImage: "lock")
                        .foregroundStyle(.secondaryText)
                } else if !lesson.hasVideo {
                    Text("This lesson has no content yet.").foregroundStyle(.secondaryText)
                }
                progressControls
            }
            .padding()
        }
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .onAppear { if done == nil { done = completed } }
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lesson.title).font(.wsTitle2).accessibilityAddTraits(.isHeader)
            if let description = lesson.description {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 8) {
                if let duration = lesson.durationText { Pill(text: duration, systemImage: "clock") }
                if lesson.isPreview { Pill(text: "Free preview", systemImage: "eye") }
                if lesson.statusValue == .draft { Pill(text: "Draft", systemImage: "pencil") }
            }
        }
    }

    @ViewBuilder
    private var video: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("academy.lesson.player")
        } else if let namespaceSlug {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await loadVideo(namespaceSlug) }
                } label: {
                    Label(loadingVideo ? "Getting the video…" : "Play the lesson video", systemImage: "play.circle.fill")
                }
                .buttonStyle(.large(.brand))
                .disabled(loadingVideo)
                .accessibilityIdentifier("academy.lesson.play")
                if let videoError { InlineErrorRow(error: videoError) { Task { await loadVideo(namespaceSlug) } } }
            }
        } else {
            Label("This lesson has a video. It plays for learners once the course is live.", systemImage: "film")
                .font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private var progressControls: some View {
        if let onToggleComplete, let isDone = done {
            VStack(spacing: 10) {
                Divider()
                Button {
                    Task {
                        working = true
                        let ok = await onToggleComplete(!isDone)
                        working = false
                        if ok {
                            done = !isDone
                            notice = .done(isDone ? "Marked as not done." : "Well done — lesson marked as done.")
                        }
                    }
                } label: {
                    Label(isDone ? "Mark as not done" : "Mark as done",
                          systemImage: isDone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                }
                .buttonStyle(.large(isDone ? .neutral : .success, prominent: !isDone))
                .disabled(working)
                .accessibilityIdentifier("academy.lesson.complete")
                if let nextLesson, let openNext {
                    Button { openNext(nextLesson) } label: {
                        Label("Next: \(nextLesson.title)", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.large(.brand, prominent: false))
                    .accessibilityIdentifier("academy.lesson.next")
                }
            }
        }
    }

    private func loadVideo(_ namespace: String) async {
        loadingVideo = true
        defer { loadingVideo = false }
        do {
            let url = try await services.academy.streamURL(namespace: namespace, lesson: lesson.uuid)
            player = AVPlayer(url: url)
            player?.play()
            videoError = nil
        } catch {
            videoError = error.asAPIError
        }
    }
}
