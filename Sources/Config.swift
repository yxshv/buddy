import Foundation

/// Personal settings, baked into the built app's Info.plist by `build.sh` from `local.env` (gitignored;
/// copy `local.env.example`). Nothing here is committed: the repo only holds the generic defaults below.
enum Config {
    private static let values = Bundle.main.object(forInfoDictionaryKey: "BuddyConfig") as? [String: String] ?? [:]

    private static func value(_ key: String) -> String? {
        guard let v = values[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }

    /// A path setting with `~` and `$HOME` expanded.
    private static func path(_ key: String, default fallback: String) -> String {
        let raw = (value(key) ?? fallback).replacingOccurrences(of: "$HOME", with: "~")
        return (raw as NSString).expandingTildeInPath
    }

    /// The app's bundle identifier (`BUDDY_BUNDLE_ID`), which also names its Keychain item.
    static let bundleID = Bundle.main.bundleIdentifier ?? "local.buddy"

    /// Codeforces solutions (`BUDDY_CF`), used by the cf-start and cf-test features.
    static let cfDir = path("BUDDY_CF", default: "~/cf")
    /// Coursework with C++ challenges (`BUDDY_CS`); the check feature looks in its `challenges` folder.
    static let csDir = path("BUDDY_CS", default: "~/cs")
    /// Where the project feature looks for folders by name (`BUDDY_PROJECTS`).
    static let projectsDir = path("BUDDY_PROJECTS", default: "~/Projects")
    /// The Obsidian publisher project, run by `buddy obsidian publish` (`BUDDY_PUBLISHER`).
    static let publisherDir = path("BUDDY_PUBLISHER", default: "~/vault-public")
    /// The published site, for result cards when the publisher doesn't print it (`BUDDY_SITE_URL`).
    static let siteURL = value("BUDDY_SITE_URL")

    /// Folders whose code Buddy never changes (`Permissions.protectedFolders`), as `~/…`.
    static var protectedFolders: [String] { [cfDir, csDir].map(tilde) }

    /// Variables passed to feature scripts, so they use the same folders.
    static var featureEnvironment: [String: String] {
        ["BUDDY_CF": cfDir, "BUDDY_CS": csDir, "BUDDY_CHALLENGES": csDir + "/challenges", "BUDDY_PROJECTS": projectsDir]
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
