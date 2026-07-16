// Temp-file cleanup — the app writes file-preview downloads and upload
// staging copies to its sandboxed temporary directory. The OS purges it
// eventually, but logout must not leave the previous user's files behind.

import Foundation

extension FileManager {
    /// Remove everything the app wrote to its temporary directory.
    func clearTemporaryFiles() {
        guard let items = try? contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in items {
            try? removeItem(at: url)
        }
    }
}
