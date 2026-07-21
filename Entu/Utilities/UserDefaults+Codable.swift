// JSON-in-UserDefaults helpers — the encode/decode plumbing shared by the
// persisted stores (SessionState snapshots, CommandPaletteModel recents,
// WindowSessionStore window list) so failure handling and any future key
// migration live in one place.

import Foundation

extension UserDefaults {
    /// Decode a Codable value stored as JSON under `key`, or nil when the
    /// key is absent or the payload doesn't decode (schema drift is treated
    /// as "no saved state", never an error).
    func codable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }

        return try? JSONDecoder().decode(type, from: data)
    }

    /// Store a Codable value as JSON under `key`. A failed encode leaves the
    /// previous value in place rather than corrupting it.
    func setCodable<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }

        set(data, forKey: key)
    }
}
