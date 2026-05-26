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
}
