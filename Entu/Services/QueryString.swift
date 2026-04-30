// Shared helper for decoding `key=val&key2=val2` query strings into a
// dictionary. Mirrors the webapp's `queryStringToObject`. Lives at
// service level because both `EntityListView` and `ReferencePickerView`
// turn a `PropertyDefinition.query` (or menu-item query) string into
// API request parameters via this exact transform.
//
// Uses `URLComponents` so percent-encoded values are decoded correctly —
// a naive `split(separator:)` walker would leave `%20` etc. intact.

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
