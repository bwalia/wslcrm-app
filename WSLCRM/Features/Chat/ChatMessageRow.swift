import SwiftUI
import UIKit

/// Reactions offered on a message: the web's quick five first, then a few more. Any emoji works
/// on the server; these are the ones a person can pick here.
enum ChatEmoji {
    static let quick = ["👍", "❤️", "😂", "🎉", "🙏"]
    static let more = ["👀", "✅", "🔥", "👏", "😮", "😢", "🙌", "💯"]
    static var all: [String] { quick + more }
}

/// What a person may do with a message, decided by the screen (the server's rules: edit your own;
/// delete your own, or anyone's if you manage the channel; pin if you manage it).
struct ChatMessageActions {
    var react: (ChatMessage, String) -> Void
    var reply: ((ChatMessage) -> Void)?
    var openThread: ((ChatMessage) -> Void)?
    var edit: (ChatMessage) -> Void
    var delete: (ChatMessage) -> Void
    var pin: ((ChatMessage) -> Void)?
    var openAttachment: (ChatAttachment) -> Void
    var jumpTo: (String) -> Void
    var canEdit: (ChatMessage) -> Bool
    var canDelete: (ChatMessage) -> Bool
}

/// A day divider ("Today", "Yesterday", "12 Nov 2026").
struct ChatDaySeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            Text(ChatDates.dayLabel(date))
                .font(.wsCaption.weight(.semibold))
                .foregroundStyle(.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color(.secondarySystemBackground), in: Capsule())
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        .padding(.vertical, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One message: avatar and name on the first of a run from the same person, the bubble (reply
/// quote, text, pictures and files), reactions, thread replies and the time. Long-press for
/// every action.
struct ChatMessageRow: View {
    let message: ChatMessage
    let myUuid: String?
    /// A follow-on from the same person within a few minutes: no avatar or name again.
    let grouped: Bool
    let apiBase: URL?
    var highlighted = false
    let actions: ChatMessageActions

    @State private var showingReactions = false
    @State private var confirmingDelete = false

    private var mine: Bool { myUuid != nil && message.userUuid == myUuid }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine {
                Spacer(minLength: 44)
            } else if grouped {
                Color.clear.frame(width: 30, height: 1)
            } else {
                ChatAvatar(name: message.senderName, seed: message.userUuid, size: 30)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !grouped, !mine {
                    Text(message.senderName)
                        .font(.wsCaption.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                        .padding(.leading, 4)
                }
                bubble
                if !message.reactions.isEmpty || showingReactions {
                    reactions
                }
                if message.replyCount > 0, let openThread = actions.openThread {
                    Button {
                        openThread(message)
                    } label: {
                        Label(message.replyCount == 1 ? "1 reply" : "\(message.replyCount) replies",
                              systemImage: "bubble.left.and.bubble.right")
                            .font(.wsFootnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("chat.message.thread")
                }
                meta
            }
            if !mine { Spacer(minLength: 44) }
        }
        .padding(.top, grouped ? 2 : 10)
        .confirmationDialog("Delete this message?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete message", role: .destructive) { actions.delete(message) }
        } message: {
            Text("It's removed for everyone in the conversation. This can't be undone.")
        }
    }

    // MARK: Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reply = message.metadata?.replyTo {
                Button {
                    actions.jumpTo(reply.uuid)
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(mine ? Color.white.opacity(0.7) : Color.accentColor)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reply.sender).font(.wsCaption.weight(.semibold))
                            Text(reply.preview).font(.wsCaption).lineLimit(2).opacity(0.85)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(mine ? Color.white.opacity(0.14) : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replying to \(reply.sender): \(reply.preview)")
                .accessibilityHint("Shows the original message")
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.wsBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                ChatAttachmentView(attachment: attachment, apiBase: apiBase, mine: mine) {
                    actions.openAttachment(attachment)
                }
            }
        }
        .foregroundStyle(mine ? Color.white : Color(.label))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(mine ? Tone.brand.solidColor : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.accentColor, lineWidth: highlighted ? 3 : 0))
        .opacity(message.isPending ? 0.65 : 1)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu { if !message.isPending { menu } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if !message.isPending {
                if let reply = actions.reply { Button("Reply") { reply(message) } }
                Button("React with thumbs up") { actions.react(message, "👍") }
                if actions.canEdit(message) { Button("Edit") { actions.edit(message) } }
                if actions.canDelete(message) { Button("Delete") { confirmingDelete = true } }
            }
        }
        .accessibilityIdentifier("chat.message")
    }

    @ViewBuilder
    private var menu: some View {
        Menu {
            ForEach(ChatEmoji.all, id: \.self) { emoji in
                Button(emoji) { actions.react(message, emoji) }
            }
        } label: {
            Label("React", systemImage: "face.smiling")
        }
        if let reply = actions.reply {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(message) }
        }
        if message.replyCount > 0, let openThread = actions.openThread {
            Button("View replies", systemImage: "bubble.left.and.bubble.right") { openThread(message) }
        }
        if !message.content.isEmpty {
            Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
        }
        if actions.canEdit(message) {
            Button("Edit", systemImage: "pencil") { actions.edit(message) }
        }
        if let pin = actions.pin {
            Button(message.isPinned ? "Unpin" : "Pin to the channel", systemImage: message.isPinned ? "pin.slash" : "pin") {
                pin(message)
            }
        }
        if actions.canDelete(message) {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
    }

    // MARK: Reactions

    private var reactions: some View {
        ChatFlowLayout(spacing: 6, alignment: mine ? .trailing : .leading) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                let chosen = reaction.includes(myUuid)
                Button {
                    actions.react(message, reaction.emoji)
                } label: {
                    Text("\(reaction.emoji) \(reaction.count)")
                        .font(.wsFootnote.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(chosen ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground),
                                    in: Capsule())
                        .overlay(Capsule().stroke(chosen ? Color.accentColor.opacity(0.6) : Color(.separator), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(reaction.emoji), \(reaction.count)\(chosen ? ", including you" : "")")
                .accessibilityHint(chosen ? "Removes your reaction" : "Adds your reaction")
            }
            Button {
                showingReactions = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.wsFootnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a reaction")
            .popover(isPresented: $showingReactions) {
                ChatEmojiPicker { emoji in
                    showingReactions = false
                    actions.react(message, emoji)
                }
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    // MARK: Meta

    private var meta: some View {
        HStack(spacing: 4) {
            if message.isPinned {
                Image(systemName: "pin.fill").accessibilityLabel("Pinned")
            }
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            if message.isEdited { Text("· edited") }
            if message.isPending { Text("· sending…") }
        }
        .font(.wsCaption2)
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, 4)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if !mine { parts.append(message.senderName) } else { parts.append("You") }
        if let reply = message.metadata?.replyTo { parts.append("replying to \(reply.sender)") }
        if !message.content.isEmpty { parts.append(message.content) }
        if !message.attachments.isEmpty {
            parts.append(message.attachments.count == 1 ? "1 attachment" : "\(message.attachments.count) attachments")
        }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        if message.isEdited { parts.append("edited") }
        if message.isPending { parts.append("sending") }
        return parts.joined(separator: ", ")
    }
}

/// A grid of reactions to pick from.
struct ChatEmojiPicker: View {
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 5), spacing: 8) {
            ForEach(ChatEmoji.all, id: \.self) { emoji in
                Button(emoji) { pick(emoji) }
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("React with \(emoji)")
            }
        }
        .padding(12)
    }
}
