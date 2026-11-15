import Foundation

/// `buddy files` and `buddy read`: looking at files never needs permission.
enum Files {
    static func url(_ path: String) -> URL {
        let expanded = (path.isEmpty ? "~" : path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
    }

    static func list(_ path: String) -> String {
        let dir = url(path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return "error: can't list \(dir.path)"
        }
        let dated = DateFormatter()
        dated.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = items.map { item -> (Bool, String) in
            let v = try? item.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory == true
            let size = isDir ? "" : ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
            let date = v?.contentModificationDate.map(dated.string) ?? ""
            return (isDir, "\(item.lastPathComponent)\(isDir ? "/" : "")\t\(size)\t\(date)")
        }
        .sorted { $0.0 != $1.0 ? $0.0 : $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        return "\(dir.path) (\(rows.count) items)\n" + rows.map(\.1).joined(separator: "\n")
    }

    static func read(_ path: String) -> String {
        let file = url(path)
        guard let data = FileManager.default.contents(atPath: file.path) else { return "error: can't read \(file.path)" }
        let limit = 200_000
        guard let text = String(data: data.prefix(limit), encoding: .utf8) else { return "error: \(file.lastPathComponent) isn't a text file" }
        return data.count > limit ? text + "\n… (\(data.count - limit) more bytes not shown)" : text
    }
}
