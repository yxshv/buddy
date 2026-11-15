import CryptoKit
import Foundation

/// The fingerprint of a feature folder: every file in it (names and bytes), so editing the script, a
/// file it reads, or feature.json changes it. Used for approval pins and, at build time, for the hashes
/// of the built-in features compiled into the app (tools/feature-hashes.swift).
enum FeatureHash {
    /// nil if the folder holds a symbolic link (which could point anywhere) or can't be read.
    static func of(_ dir: URL) -> String? {
        let root = dir.standardizedFileURL.resolvingSymlinksInPath()
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: []) else { return nil }
        var files: [(String, URL)] = []
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return nil }
            if v.isSymbolicLink == true { return nil }
            guard v.isRegularFile == true, url.lastPathComponent != ".DS_Store" else { continue }
            let relative = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            files.append((relative, url))
        }
        var hasher = SHA256()
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            hasher.update(data: Data(relative.utf8) + Data([0]))
            hasher.update(data: bytes)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
