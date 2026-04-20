// HTTP client for the Entu REST API.
// Handles URL building, authentication headers, JSON encoding/decoding,
// and auto-logout on 401 responses.
//
// Multi-tenant: when databaseId is set, all requests are scoped to that database
// (e.g. /api/{databaseId}/entity). Auth routes skip the database prefix.
//
// @Observable = SwiftUI views update when databaseId or token change.
// @MainActor = properties are read/written on the main thread.

import Foundation

/// API error types for HTTP failures.
enum APIError: LocalizedError {
    case unauthorized
    case serverError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Unauthorized"
        case .serverError(let code, let message): return "Error \(code): \(message)"
        case .invalidResponse: return "Invalid response"
        }
    }
}

/// HTTP client for the Entu REST API with JWT auth and auto-logout.
@MainActor @Observable
final class APIClient {
    static let baseURL = "https://entu.app/api"

    /// Active database scope for all non-auth requests.
    var databaseId: String?

    /// JWT bearer token for authenticated requests.
    var token: String?

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

    /// GET using a one-time bearer token instead of the stored token — for the auth callback flow.
    func requestWithToken<T: Decodable>(_ path: String, params: [String: String] = [:], bearerToken: String) async throws -> T {
        try await performRequest(path, method: "GET", params: params, tokenOverride: bearerToken)
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
        let bearerToken = tokenOverride ?? currentToken

        #if DEBUG
        print("[API] \(method) \(url.path)?\(url.query ?? "")")
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
            await MainActor.run { onUnauthorized?() }
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
