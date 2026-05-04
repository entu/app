// HTTP client for the Entu REST API.
// Handles URL building, authentication headers, JSON encoding/decoding,
// and auto-logout on 401 responses (skipped while browsing a public database).
//
// Multi-tenant: when databaseId is set, all requests are scoped to that database
// (e.g. /api/{databaseId}/entity). Auth routes skip the database prefix.
// `suppressToken` lets a signed-in user browse a public database as a guest
// by omitting the Authorization header on every request without losing the
// stored token. `probePublicDatabase` runs alongside this for the
// "Browse public database" entry flow — it builds the URL by hand so the
// candidate id never lands in `databaseId` before it's been confirmed
// readable without a token.
//
// @Observable = SwiftUI views update when databaseId, token, or suppressToken change.
// @MainActor = properties are read/written on the main thread.

import Foundation

/// Result of probing a candidate database for public access.
enum PublicDatabaseProbe {
    case found
    case notFound
    case notPublic
}

/// API error types for HTTP failures.
enum APIError: LocalizedError {
    case unauthorized
    case serverError(Int, String)
    case invalidResponse
    case noAccessibleDatabases

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Unauthorized"
        case .serverError(let code, let message): return "Error \(code): \(message)"
        case .invalidResponse: return "Invalid response"
        case .noAccessibleDatabases: return "No accessible databases for this account"
        }
    }
}

/// HTTP client for the Entu REST API with JWT auth and auto-logout.
@MainActor @Observable
final class APIClient {
    nonisolated static let baseURL = "https://api.entu.app"

    /// Active database scope for all non-auth requests.
    var databaseId: String?

    /// JWT bearer token for authenticated requests.
    var token: String?

    /// When true, requests omit the Authorization header even if `token` is set.
    /// Toggled by `AuthModel.selectPublicDatabase(_:)` so signed-in users can
    /// browse a public database as a guest. Auth callbacks bypass this via
    /// `tokenOverride`. A 401 in this mode is reported back to the caller
    /// instead of triggering the auto-logout hook (the user has nothing to log
    /// out *of*).
    var suppressToken: Bool = false

    /// Fires on 401 responses — set by AuthModel to trigger automatic logout.
    var onUnauthorized: (() -> Void)?

    /// GET a decoded JSON response from the given path with optional query params.
    func get<T: Decodable>(_ path: String, params: [String: String] = [:]) async throws -> T {
        try await performRequest(path, method: "GET", params: params)
    }

    /// POST an encodable body and return the decoded response.
    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await performRequest(path, method: "POST", bodyData: try JSONEncoder().encode(body))
    }

    /// POST with no body and return the decoded response.
    func post<T: Decodable>(_ path: String) async throws -> T {
        try await performRequest(path, method: "POST")
    }

    /// DELETE the resource at the given path and return the decoded response.
    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await performRequest(path, method: "DELETE")
    }

    /// Resolve a file property to a local URL ready for QuickLook. Hits
    /// `GET /property/{id}` for a 60 s presigned S3 URL, downloads the
    /// bytes, and writes them to the temp dir under `filename` (falling
    /// back to the property id when no name is known). Returns `nil` on
    /// any failure — callers display nothing.
    func downloadFileForPreview(propertyId: String, filename: String?) async -> URL? {
        struct FilePropertyResponse: Decodable { let url: String? }
        guard let response: FilePropertyResponse = try? await get("property/\(propertyId)"),
              let urlString = response.url,
              let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename ?? propertyId)
        guard (try? data.write(to: dest)) != nil else { return nil }
        return dest
    }

    /// Stream a file from disk to an S3 presigned URL described by an
    /// `UploadIntent`. `Content-Length` is stripped — URLSession derives
    /// it from the file's size, and S3 rejects a duplicate. `onProgress`
    /// receives 0…1 fractions on the main actor as bytes go up.
    ///
    /// Streaming via `upload(for:fromFile:)` keeps memory bounded — works
    /// for multi-GB uploads where loading into `Data` would crash.
    nonisolated func uploadFile(
        intent: UploadIntent,
        fileURL: URL,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let url = URL(string: intent.url) else { throw APIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = intent.method
        for (header, value) in intent.headers ?? [:] {
            if header.lowercased() == "content-length" { continue }
            request.setValue(value, forHTTPHeaderField: header)
        }

        let delegate = onProgress.map { UploadProgressDelegate(callback: $0) }
        let (data, response) = try await URLSession.shared.upload(
            for: request,
            fromFile: fileURL,
            delegate: delegate
        )
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode >= 400 {
            // S3 returns its actual reason in the response body (XML), e.g.
            // "SignatureDoesNotMatch", "AccessDenied". Surface it so the
            // commit-error toast carries more than a generic "Upload failed".
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(http.statusCode, body.isEmpty ? "Upload failed" : body)
        }
    }

    /// GET using a one-time bearer token instead of the stored token — for the auth callback flow.
    func requestWithToken<T: Decodable>(_ path: String, params: [String: String] = [:], bearerToken: String) async throws -> T {
        try await performRequest(path, method: "GET", params: params, tokenOverride: bearerToken)
    }

    /// Probe whether `{databaseId}` exists and is publicly accessible, without
    /// touching the active session state. Builds the URL by hand instead of
    /// going through `buildURL` so the candidate id never lands in `databaseId`.
    /// Returns `.found` for any 2xx, `.notFound` for 404, `.notPublic` for any
    /// other 4xx (including 401 against a private database). Network errors
    /// throw.
    nonisolated func probePublicDatabase(_ databaseId: String) async throws -> PublicDatabaseProbe {
        var components = URLComponents(string: APIClient.baseURL)!
        components.path += "/\(databaseId)/entity"
        components.queryItems = [
            URLQueryItem(name: "_type.string", value: "database"),
            URLQueryItem(name: "props", value: "name"),
            URLQueryItem(name: "limit", value: "1")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        // Intentionally no Authorization header — public reads only.

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300: return .found
        case 404: return .notFound
        case 400..<500: return .notPublic
        default: throw APIError.serverError(http.statusCode, "")
        }
    }

    // MARK: - Internal

    // "nonisolated" = this method can run off the main thread.
    // It reads main-actor properties via "await", then does the network call
    // on a background thread to avoid blocking the UI.
    nonisolated private func performRequest<T: Decodable>(
        _ path: String,
        method: String,
        params: [String: String] = [:],
        bodyData: Data? = nil,
        tokenOverride: String? = nil
    ) async throws -> T {
        let url = await buildURL(path: path, params: method == "GET" ? params : [:])
        let currentToken = await token
        let suppress = await suppressToken
        let bearerToken = tokenOverride ?? (suppress ? nil : currentToken)

        #if DEBUG
        let queryString = url.query.map { "?\($0)" } ?? ""
        print("[API] \(method) \(url.path)\(queryString)")
        #endif

        var request = URLRequest(url: url)
        request.httpMethod = method

        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            // Don't auto-logout when the request was already running without a
            // token (public-database browsing) — the 401 means the database
            // isn't actually public, not that the user's token went bad.
            if !suppress {
                await MainActor.run { onUnauthorized?() }
            }
            throw APIError.unauthorized
        }

        if httpResponse.statusCode >= 400 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(httpResponse.statusCode, message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // Build the full URL with database prefix and query parameters.
    // Auth routes and "new" skip the database prefix.
    private func buildURL(path: String, params: [String: String]) -> URL {
        var components = URLComponents(string: APIClient.baseURL)!

        if let databaseId, !path.starts(with: "auth") && path != "new" {
            components.path += "/\(databaseId)/\(path)"
        } else if !path.isEmpty {
            components.path += "/\(path)"
        }

        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        return components.url!
    }
}

/// `URLSessionTaskDelegate` that forwards `didSendBodyData` ticks as a
/// 0…1 fraction. Hops to the main actor so the SwiftUI `EditableValue`
/// can be updated without isolation warnings.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let callback: @MainActor @Sendable (Double) -> Void

    init(callback: @escaping @MainActor @Sendable (Double) -> Void) {
        self.callback = callback
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in callback(fraction) }
    }
}
