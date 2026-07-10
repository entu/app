import Foundation

extension String {
    /// Decode a URL query string ("a=1&b=hello%20world") into its
    /// key→value dictionary. Empty input returns an empty dictionary.
    func parseURLQuery() -> [String: String] {
        guard !isEmpty else { return [:] }
        var components = URLComponents()
        components.query = self
        var dict: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            dict[item.name] = value
        }
        return dict
    }

    /// Decode a URL query string into ordered key/value pairs. Unlike
    /// `parseURLQuery()`, preserves parameter order — used where order
    /// matters (e.g. re-populating the advanced-search form rows).
    func parseURLQueryItems() -> [(String, String)] {
        guard !isEmpty else { return [] }
        var components = URLComponents()
        components.query = self
        return (components.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }
    }
}

extension Array where Element == (String, String) {
    /// Encode ordered key/value pairs into a URL query string — inverse of
    /// `parseURLQueryItems()`. Order is preserved so the result is
    /// deterministic for view identity (`.task(id:)`).
    func buildURLQuery() -> String {
        guard !isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.query ?? ""
    }
}
