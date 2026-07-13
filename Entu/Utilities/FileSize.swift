import Foundation

extension Int {
    /// Human-readable file size in Finder's `.file` style, e.g. "1.2 MB".
    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
