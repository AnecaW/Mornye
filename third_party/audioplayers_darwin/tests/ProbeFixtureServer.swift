import Foundation
import Network

/// Bundled synthetic audio only, served on IPv4 loopback. No NAS credentials
/// or user files enter this diagnostic server.
final class ProbeFixtureServer: @unchecked Sendable {
  private let root: URL
  private let queue = DispatchQueue(label: "mornye.audio-probe.http")
  private var listener: NWListener?
  private final class StartState: @unchecked Sendable { var completed = false }

  init(root: URL) { self.root = root }

  func start() async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      connection.start(queue: self.queue)
      self.receive(connection, previous: Data())
      self.queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }
    return try await withCheckedThrowingContinuation { continuation in
      let startState = StartState()
      listener.stateUpdateHandler = { [weak listener] state in
        guard !startState.completed else { return }
        switch state {
        case .ready:
          startState.completed = true
          continuation.resume(returning: listener!.port!.rawValue)
        case .failed(let error):
          startState.completed = true
          continuation.resume(throwing: error)
        case .cancelled:
          startState.completed = true
          continuation.resume(throwing: CancellationError())
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener?.cancel(); listener = nil }

  private func receive(_ connection: NWConnection, previous: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
      [weak self] bytes, _, finished, error in
      guard let self else { connection.cancel(); return }
      var request = previous
      if let bytes { request.append(bytes) }
      guard request.count <= 16384 else { connection.cancel(); return }
      if request.range(of: Data("\r\n\r\n".utf8)) != nil {
        self.respond(connection, request: String(decoding: request, as: UTF8.self))
      } else if !finished && error == nil {
        self.receive(connection, previous: request)
      } else { connection.cancel() }
    }
  }

  private func respond(_ connection: NWConnection, request: String) {
    let lines = request.components(separatedBy: "\r\n")
    let first = (lines.first ?? "").split(separator: " ")
    guard first.count >= 2, ["GET", "HEAD"].contains(String(first[0])) else {
      send(connection, status: "405 Method Not Allowed"); return
    }
    let target = String(first[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    guard let decoded = String(target).removingPercentEncoding else {
      send(connection, status: "400 Bad Request"); return
    }
    let parts = decoded.split(separator: "/").map(String.init)
    guard !parts.isEmpty, parts.count <= 3,
      !parts.contains(".."), !parts.contains("."),
      parts.allSatisfy({ !$0.contains("\\") }) else {
      send(connection, status: "404 Not Found"); return
    }
    let name = parts.joined(separator: "/")
    let allowed = ["tone.wav", "tone.flac", "tone.mp3"].contains(name)
      || (["high", "low", "cmaf"].contains(parts[0]) &&
        ["m3u8", "ts", "m4s", "mp4", "aac"].contains((name as NSString).pathExtension))
    let file = root.appendingPathComponent(name)
    guard allowed, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
      size > 0, size <= 8 * 1024 * 1024, let bytes = try? Data(contentsOf: file) else {
      send(connection, status: "404 Not Found"); return
    }
    let types = ["wav": "audio/wav", "flac": "audio/flac", "mp3": "audio/mpeg",
      "m3u8": "application/vnd.apple.mpegurl", "ts": "video/mp2t", "mp4": "audio/mp4",
      "m4s": "audio/mp4", "aac": "audio/aac"]
    var headers = ["Content-Type": types[file.pathExtension] ?? "application/octet-stream",
      "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
    var start = 0, end = bytes.count - 1, partial = false
    if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
      let value = rangeLine.dropFirst(6).trimmingCharacters(in: .whitespaces)
      let ranges = value.hasPrefix("bytes=") ? value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false) : []
      guard ranges.count == 2 else {
        send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(bytes.count)"]); return
      }
      if ranges[0].isEmpty, let suffix = Int(ranges[1]), suffix > 0 {
        start = max(0, bytes.count - suffix)
      } else if let offset = Int(ranges[0]) {
        start = offset
        if !ranges[1].isEmpty { end = min(Int(ranges[1]) ?? -1, end) }
      } else { start = -1 }
      guard start >= 0, start < bytes.count, end >= start else {
        send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(bytes.count)"]); return
      }
      partial = true
      headers["Content-Range"] = "bytes \(start)-\(end)/\(bytes.count)"
    }
    let length = end - start + 1
    headers["Content-Length"] = String(length)
    send(connection, status: partial ? "206 Partial Content" : "200 OK", headers: headers,
      body: first[0] == "HEAD" ? Data() : bytes.subdata(in: start..<(end + 1)))
  }

  private func send(_ connection: NWConnection, status: String,
    headers: [String: String] = [:], body: Data = Data()) {
    var fields = headers
    if fields["Content-Length"] == nil { fields["Content-Length"] = String(body.count) }
    fields["Connection"] = "close"
    var response = Data(("HTTP/1.1 \(status)\r\n" +
      fields.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }
}
