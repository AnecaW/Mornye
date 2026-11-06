import AVFoundation
import CryptoKit

/// AVPlayer supplies timed ID3/HLS metadata; no second media decoder is opened.
final class StreamMetadata: NSObject, AVPlayerItemMetadataOutputPushDelegate {
  private(set) var values: [String: String] = [:]
  let output = AVPlayerItemMetadataOutput(identifiers: nil)

  override init() {
    super.init()
    output.setDelegate(self, queue: .main)
  }

  func metadataOutput(_ output: AVPlayerItemMetadataOutput,
    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
    from track: AVPlayerItemTrack?) {
    var next: [String: String] = [:]
    for item in groups.flatMap({ $0.items }) {
      if item.commonKey == .commonKeyArtwork, let data = item.dataValue,
        !data.isEmpty, data.count <= 2 * 1024 * 1024,
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
        let root = directory.appendingPathComponent("MornyeRadioArtwork", isDirectory: true)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(digest + ".img")
        do {
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
          next["artwork"] = file.absoluteString
          let cached = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey])
          if cached.count > 8 {
            for old in cached.filter({ $0 != file }).sorted(by: {
              let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
              let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
              return left < right
            }).prefix(cached.count - 8) { try? FileManager.default.removeItem(at: old) }
          }
        } catch { /* Artwork lookup remains optional; broadcast playback continues. */ }
        continue
      }
      guard let text = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty, text.utf8.count <= 4096 else { continue }
      let key = item.commonKey?.rawValue ?? ""
      let identifier = item.identifier?.rawValue ?? ""
      if key == "title" || identifier.hasSuffix("TIT2") { next["title"] = text }
      else if key == "artist" || identifier.hasSuffix("TPE1") { next["artist"] = text }
      else if key == "albumName" || identifier.hasSuffix("TALB") { next["album"] = text }
      else if identifier.lowercased().contains("streamtitle") { next["streamTitle"] = text }
    }
    // Replace a whole track atomically: never carry the previous song's album.
    if next["title"] != nil || next["streamTitle"] != nil { values = next }
  }
}
