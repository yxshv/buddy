import Foundation

/// Listens on a Unix socket only you can reach (`~/Library/Application Support/Buddy/buddy.sock`)
/// for the `buddy` CLI. Each connection sends one JSON line `{"args": [...], "stdin": "..."}` and gets
/// the command's reply back as text before the socket closes.
final class CommandServer {
    static let path: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("buddy.sock").path
    }()

    private let handle: (_ args: [String], _ stdin: String, _ reply: @escaping (String) -> Void) -> Void
    private var listener: Int32 = -1

    init(handle: @escaping (_ args: [String], _ stdin: String, _ reply: @escaping (String) -> Void) -> Void) {
        self.handle = handle
    }

    func start() {
        unlink(Self.path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, Self.path, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { close(listener); listener = -1; return }
        chmod(Self.path, 0o600) // only your user account can talk to Buddy

        let fd = listener
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { if errno == EINTR { continue } else { return } }
                Thread.detachNewThread { self?.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !data.contains(0x0A) {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let line = data.split(separator: 0x0A).first ?? Data()
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let args = request["args"] as? [String] else {
            send("error: bad request", to: client)
            return
        }
        let stdin = request["stdin"] as? String ?? ""
        DispatchQueue.main.async {
            self.handle(args, stdin) { reply in
                DispatchQueue.global().async { self.send(reply, to: client) }
            }
        }
    }

    private func send(_ text: String, to client: Int32) {
        let bytes = Array((text.hasSuffix("\n") ? text : text + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            sent += n
        }
        close(client)
    }
}
