import Foundation

// `buddy`: the command line for the running Buddy app. It forwards its arguments (and anything piped
// in) to Buddy over a local socket and prints the reply. The commands themselves live in the app
// (Sources/Commands.swift); `buddy help` lists them.
//
// Exit codes: 0 done, 1 error (or Buddy isn't running), 2 the user declined.

let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Buddy/buddy.sock").path

// Text piped in (for long notes and boards). Only read it if some is actually there: a terminal, or an
// open pipe nobody writes to (as in some shells), would otherwise wait forever.
var stdinText = ""
var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
if isatty(STDIN_FILENO) == 0, poll(&input, 1, 100) > 0, input.revents & Int16(POLLIN) != 0 {
    stdinText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let capacity = MemoryLayout.size(ofValue: addr.sun_path)
withUnsafeMutablePointer(to: &addr.sun_path) {
    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard fd >= 0, connected == 0 else {
    FileHandle.standardError.write(Data("Buddy isn't running. Open /Applications/Buddy.app first.\n".utf8))
    exit(1)
}

let request: [String: Any] = ["args": Array(CommandLine.arguments.dropFirst()), "stdin": stdinText]
var payload = try! JSONSerialization.data(withJSONObject: request)
payload.append(0x0A)
_ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

var reply = Data()
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    reply.append(contentsOf: buffer[0..<n])
}
close(fd)

let text = String(decoding: reply, as: UTF8.self)
print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
exit(text.hasPrefix("error") ? 1 : text.hasPrefix("declined") ? 2 : 0)
