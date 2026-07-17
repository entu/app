// Entu AI conversation state — message list, the chat + execute API
// calls, and the proposal review flow. Mirrors webapp's `stores/chat.js`.

import Foundation

/// Conversation state for the Entu AI assistant. Mirrors the webapp store
/// (`stores/chat.js`): holds the message list, drives the two
/// API calls (chat + execute), and manages the proposal review flow.
///
/// Account-scoped like the webapp — the conversation resets when the active
/// database changes (driven by `MainView`, guarded by `syncDatabase()`).
@MainActor @Observable
final class AIChatModel {
    /// Max messages sent to the API per request (matches webapp).
    static let maxHistoryMessages = 40

    /// Max characters per message sent to the API (matches webapp).
    static let maxMessageLength = 8000

    var messages: [ChatMessage] = []

    /// Whether the chat sheet is presented.
    var isOpen = false

    /// Awaiting an assistant reply.
    var isLoading = false

    /// Applying a confirmed proposal.
    var isExecuting = false

    /// Bumped after a proposal is applied with at least one result, so
    /// `MainView` can reload the menu and refresh the entity list.
    private(set) var appliedToken = 0

    private let api: APIClient

    /// Database the current conversation belongs to — reset on switch.
    private var boundDatabaseId: String?

    init(api: APIClient) {
        self.api = api
    }

    /// Messages shown in the UI — hidden system-context entries are excluded.
    var visibleMessages: [ChatMessage] {
        messages.filter { !$0.hidden }
    }

    /// Id of the last assistant proposal still awaiting the user's decision,
    /// or `nil` when there is none. Mirrors the webapp's `pendingMessage`.
    var pendingMessageId: ChatMessage.ID? {
        messages.last {
            $0.role == .assistant && $0.proposal != nil
                && $0.executionResults == nil && !$0.declined
        }?.id
    }

    /// Clear the conversation and close the panel (e.g. on account switch
    /// or cache clear).
    func reset() {
        messages = []
        isLoading = false
        isExecuting = false
        isOpen = false
    }

    // MARK: - Chat

    /// Send a user message and append the assistant's reply. On failure the
    /// error is attached to the user message, matching the webapp.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading, !isExecuting else { return }

        syncDatabase()
        messages.append(ChatMessage(role: .user, content: trimmed))
        let userIndex = messages.count - 1

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.aiChat(messages: apiHistory())
            var assistant = ChatMessage(role: .assistant, content: response.message)
            assistant.proposal = response.proposal
            messages.append(assistant)
        } catch {
            messages[userIndex].error = Self.errorText(error)
        }
    }

    // MARK: - Proposal review

    /// Apply the proposal on the given message via `/ai/execute`, then record
    /// the outcome and a summary. Mirrors the webapp's `confirm`.
    func confirm(_ messageId: ChatMessage.ID) async {
        guard !isExecuting,
              let index = messages.firstIndex(where: { $0.id == messageId }),
              let operations = messages[index].proposal?.operations else { return }

        isExecuting = true
        defer { isExecuting = false }

        do {
            let results = try await api.aiExecute(operations: operations)
            messages[index].executionResults = results

            // Record the outcome as hidden context so a follow-up question
            // knows the changes were applied.
            messages.append(ChatMessage(
                role: .user,
                content: "[User confirmed the proposed changes and all applicable operations were executed]",
                hidden: true
            ))

            var summaryMessage = ChatMessage(role: .assistant, content: "", local: true)
            summaryMessage.summary = ExecutionSummary(
                applied: results.results?.count ?? 0,
                total: operations.count,
                failed: results.error != nil
            )
            messages.append(summaryMessage)

            // New entity types / entities may have appeared — invalidate caches
            // and let MainView reload the menu and entity list.
            if results.results?.isEmpty == false {
                EntityDetailModel.clearCache()
                MenuModel.clearCache()
                appliedToken &+= 1
            }
        } catch {
            messages[index].error = Self.errorText(error)
        }
    }

    /// Decline the proposal on the given message. Mirrors the webapp's `reject`.
    func reject(_ messageId: ChatMessage.ID) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        messages[index].declined = true
        messages.append(ChatMessage(
            role: .user,
            content: "[User declined the proposed changes]",
            hidden: true
        ))
    }

    // MARK: - Internal

    /// Reset the conversation if the active database changed since it began,
    /// so a stale conversation never leaks across accounts.
    private func syncDatabase() {
        if boundDatabaseId != api.databaseId {
            messages = []
            boundDatabaseId = api.databaseId
        }
    }

    /// Build the message history sent to the API: drop errored and local-only
    /// messages, keep the last 40, and cap each at 8000 characters.
    private func apiHistory() -> [AIChatRequest.Message] {
        messages
            .filter { $0.error == nil && !$0.local }
            .suffix(Self.maxHistoryMessages)
            .map {
                AIChatRequest.Message(
                    role: $0.role.rawValue,
                    content: String($0.content.prefix(Self.maxMessageLength))
                )
            }
    }

    /// Human-readable error text. Surfaces the API's status message, with a
    /// friendlier line for the monthly token limit (402).
    private static func errorText(_ error: Error) -> String {
        guard case let APIError.serverError(code, body) = error else {
            return error.localizedDescription
        }

        if code == 402 {
            return String(localized: "aiTokenLimit", bundle: .currentLocalized)
        }

        if let data = body.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(APIErrorBody.self, from: data),
           let message = parsed.statusMessage ?? parsed.message {
            return message
        }

        return body.isEmpty ? String(localized: "aiError", bundle: .currentLocalized) : body
    }

    private struct APIErrorBody: Decodable {
        let message: String?
        let statusMessage: String?
    }
}
