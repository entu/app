// One message bubble in the AI chat. User messages are right-aligned teal
// bubbles; assistant messages render as Markdown, optionally with a
// proposal card or an applied-changes summary. Mirrors the webapp's
// `components/chat/message.vue`.

import SwiftUI

/// A single chat message row.
struct ChatMessageView: View {
    let message: ChatMessage
    let isPending: Bool
    let isExecuting: Bool
    let onApply: () -> Void
    let onCancel: () -> Void
    let onOpenEntity: (String) -> Void


    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantContent
        }
    }

    // MARK: - User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(message.content)
                    .textSelection(.enabled)

                if let error = message.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            // Accent bubble with a tucked bottom-trailing corner, per the design.
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 15,
                    bottomLeadingRadius: 15,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 15
                )
                .fill(Color.accentColor)
            )
            .foregroundStyle(.white)
        }
    }

    // MARK: - Assistant

    @ViewBuilder
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summaryText {
                Label(summaryText, systemImage: message.summary?.failed == true
                    ? "exclamationmark.triangle"
                    : "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if !message.content.isEmpty {
                    Text(markdown(message.content))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let proposal = message.proposal {
                    ChatProposalView(
                        operations: proposal.operations,
                        results: message.executionResults,
                        isPending: isPending,
                        isExecuting: isExecuting,
                        declined: message.declined,
                        onApply: onApply,
                        onCancel: onCancel,
                        onOpenEntity: onOpenEntity
                    )
                }

                if let error = message.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Summary line for a local execution-summary message.
    private var summaryText: LocalizedStringKey? {
        guard let summary = message.summary else { return nil }

        if !summary.failed {
            return "aiAllApplied"
        }
        return "aiSomeApplied \(summary.applied) \(summary.total)"
    }

    /// Parse assistant text as Markdown, falling back to plain text — matches
    /// `PropertyRow`'s use of `AttributedString(markdown:)`.
    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}
