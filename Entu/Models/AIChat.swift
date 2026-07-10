import Foundation

/// A single message in the Entu AI conversation. Mirrors the webapp store's
/// message shape (`webapp/app/stores/chat.js`): user/assistant text plus
/// optional proposal, execution results, and local/hidden bookkeeping.
struct ChatMessage: Identifiable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id = UUID()
    var role: Role
    var content: String

    /// Write operations the assistant queued for the user to review.
    var proposal: Proposal?

    /// Result of applying `proposal` via `/ai/execute`.
    var executionResults: ExecutionResults?

    /// User rejected the proposal — no execution attempted.
    var declined: Bool = false

    /// Error text shown under the message when the request failed.
    var error: String?

    /// System context recorded for API history but never shown in the UI.
    var hidden: Bool = false

    /// Local-only message (execution summary) not sent back to the API.
    var local: Bool = false

    /// Populated on `local` summary messages after a proposal is applied.
    var summary: ExecutionSummary?
}

/// A batch of write operations the assistant proposes but never applies —
/// the user confirms via `/ai/execute`.
struct Proposal: Codable, Sendable {
    let operations: [ProposalOperation]
}

/// One operation in a proposal. Known fields are decoded for display;
/// `params`/`properties` are preserved as raw JSON so the whole operation
/// round-trips unchanged into `/ai/execute`.
struct ProposalOperation: Codable, Sendable {
    let op: String
    let tempId: String?
    let description: String?
    /// Actual parameters sent to `/ai/execute`.
    let params: JSONValue?
    /// Human-readable preview of the properties that will be set.
    let properties: JSONValue?

    /// Text shown when the user expands an operation's details — the
    /// property preview when present, otherwise the raw params.
    var detailText: String? {
        (properties ?? params)?.prettyText
    }
}

/// Result of `/ai/execute` — created/updated entity ids in order, plus the
/// first failure (execution stops there).
struct ExecutionResults: Codable, Sendable {
    struct Result: Codable, Sendable {
        let tempId: String?
        let _id: String?
        let op: String?
    }

    struct ExecutionError: Codable, Sendable {
        let index: Int
        let statusCode: Int?
        let statusMessage: String?
    }

    let results: [Result]?
    let error: ExecutionError?
}

/// Per-operation outcome after a proposal is executed, mirroring the
/// webapp's `opStatus` (`components/chat/proposal.vue`).
enum OperationStatus {
    case applied
    case failed
    case skipped

    /// Resolve the status of the operation at `index` given execution results.
    /// Returns `nil` while the proposal is still pending.
    static func resolve(index: Int, results: ExecutionResults?) -> OperationStatus? {
        guard let results else { return nil }

        guard let error = results.error else { return .applied }

        if index < error.index { return .applied }
        if index == error.index { return .failed }

        return .skipped
    }
}

/// Summary shown after a proposal is applied.
struct ExecutionSummary: Sendable {
    let applied: Int
    let total: Int
    let failed: Bool
}

// MARK: - API request / response shapes

/// Request body for `POST /{db}/ai/chat`.
struct AIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let messages: [Message]
}

/// Response body from `POST /{db}/ai/chat`.
struct AIChatResponse: Decodable {
    let message: String
    let proposal: Proposal?
}

/// Request body for `POST /{db}/ai/execute`.
struct AIExecuteRequest: Encodable {
    let operations: [ProposalOperation]
}
