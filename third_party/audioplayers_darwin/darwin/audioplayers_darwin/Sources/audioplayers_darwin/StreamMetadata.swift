import AVFoundation

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
