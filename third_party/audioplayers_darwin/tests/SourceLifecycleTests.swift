import AVFoundation
import Foundation

// Only Flutter's channel boundary is stubbed. Holding an item outside a real
// AVPlayer keeps its status unknown so cancellation is deterministic.
@MainActor final class AudioplayersDarwinPlugin {
  func controlAudioSession() {}
}

final class AudioPlayersStreamHandler {
  var preparedCount = 0
  var completedCount = 0
  var seekCompletedCount = 0

  func onSeekComplete() { seekCompletedCount += 1 }
  func onPrepared(isPrepared: Bool) { if isPrepared { preparedCount += 1 } }
  func onLog(message: String) {}
  func onDuration(millis: Int) {}
  func onComplete() { completedCount += 1 }
  func dispose() {}
  func onError(code: String, message: String, details: String) {}
}

final class DeferredPlayer: AVPlayer {
  private var item: AVPlayerItem?
  var pauseCount = 0

  override var currentItem: AVPlayerItem? { item }

  override func replaceCurrentItem(with item: AVPlayerItem?) {
    self.item = item
  }

  override func pause() {
    pauseCount += 1
  }
}

final class DeferredSeekItem: AVPlayerItem {
  var pendingSeek: ((Bool) -> Void)?

  override func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completionHandler: ((Bool) -> Void)? = nil
  ) {
    pendingSeek = completionHandler
  }
}

@main struct SourceLifecycleTests {
  enum Failure: Error {
    case message(String)
  }

  @MainActor final class Preparation {
    var result: Result<Void, Error>?

    init(_ wrapper: WrappedMediaPlayer, url: String, isLocal: Bool = true) {
      Task { @MainActor in
        do {
          try await wrapper.setSourceUrl(url: url, isLocal: isLocal)
          result = .success(())
        } catch {
          result = .failure(error)
        }
      }
    }
  }

  @MainActor static func waitFor(_ message: String, until condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw Failure.message(message)
  }

  @MainActor static func requireCancelled(_ preparation: Preparation) async throws {
    try await waitFor("A cancelled source never completed") { preparation.result != nil }
    guard case .failure = preparation.result else {
      throw Failure.message("A cancelled source was reported as prepared")
    }
  }

  static func writeSilence(to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  @MainActor static func testNativePreparationAndStaleCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.wav")
    let secondURL = root.appendingPathComponent("second.wav")
    try writeSilence(to: firstURL)
    try writeSilence(to: secondURL)

    let native = AVPlayer()
    native.isMuted = true
    let events = AudioPlayersStreamHandler()
    let wrapper = WrappedMediaPlayer(
      reference: AudioplayersDarwinPlugin(), eventHandler: events, player: native)
    let first = Preparation(wrapper, url: firstURL.path)
    try await waitFor("Native source did not finish preparation") { first.result != nil }
    guard case .success = first.result, events.preparedCount == 1, wrapper.getDuration() == 1000,
      let oldItem = native.currentItem
    else { throw Failure.message("Native source did not prepare successfully") }

    let configuration: [String: Any] = ["enabled": true,
      "frequencies": [60.0, 250.0, 1000.0, 4000.0, 16000.0],
      "gains": [0.0, 0.0, 0.0, 0.0, 0.0], "inputGain": -6.0]
    try await EqualizerAudioTap.attach(to: oldItem, processor: EqualizerAudioTap(),
      shouldAttach: { false })
    guard oldItem.audioMix == nil else {
      throw Failure.message("A retired EQ request installed a mix")
    }
    try await wrapper.setEqualizer(configuration)
    guard !wrapper.isPlaying, oldItem.audioMix != nil else {
      throw Failure.message("EQ did not install on the current paused item or started playback")
    }
    wrapper.resume()
    try await wrapper.setEqualizer(configuration)
    guard wrapper.isPlaying else {
      throw Failure.message("An EQ update discarded the current Play intent")
    }
    wrapper.pause()
    try await wrapper.setEqualizer(configuration)
    guard !wrapper.isPlaying else {
      throw Failure.message("An EQ update resumed a user-paused track")
    }
    print("PASS: EQ retains Play/Pause intent and rejects a retired attachment")
    wrapper.resume()
    // Delivery queues a MainActor task. Replace the item before that task runs.
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
    try await wrapper.setSourceUrl(url: secondURL.path, isLocal: true)
    try await Task.sleep(nanoseconds: 50_000_000)
    guard events.completedCount == 0, native.currentItem != nil else {
      throw Failure.message("The old item's queued completion affected its replacement")
    }
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: native.currentItem)
    try await waitFor("The current item's completion was not delivered and released") {
      events.completedCount == 1 && native.currentItem == nil
    }

    let failed = Preparation(wrapper, url: root.appendingPathComponent("missing.wav").path)
    try await waitFor("Missing native source did not fail preparation") { failed.result != nil }
    guard case .failure(let error) = failed.result, !(error is CancellationError),
      native.currentItem == nil, events.preparedCount == 2
    else {
      throw Failure.message("Missing native source was not reported as a preparation failure")
    }
    guard case AudioPlayerError.error(let message) = error,
      message.contains("ErrorDomain")
    else {
      throw Failure.message("Native preparation failure lost its NSError domain and code")
    }
    await wrapper.dispose()
  }

  @MainActor static func testSourceDiagnostics() throws {
    let cause = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
      userInfo: [
        NSURLErrorFailingURLErrorKey: URL(string: "https://user:secret@nas.test/private.flac")!
      ])
    let error = NSError(
      domain: AVFoundationErrorDomain, code: -11800,
      userInfo: [NSUnderlyingErrorKey: cause, NSLocalizedDescriptionKey: "secret URL"])
    guard case .error(let message) = WrappedMediaPlayer.sourceError(error),
      message.contains("\(AVFoundationErrorDomain) (-11800)"),
      message.contains("\(NSURLErrorDomain) (\(NSURLErrorCannotConnectToHost))"),
      !message.contains("secret"), !message.contains("nas.test")
    else {
      throw Failure.message("Source diagnostics lost the native cause or exposed private userInfo")
    }
  }

  @MainActor static func testNetworkPreparation(_ url: String) async throws {
    let native = AVPlayer()
    let events = AudioPlayersStreamHandler()
    let wrapper = WrappedMediaPlayer(
      reference: AudioplayersDarwinPlugin(), eventHandler: events, player: native)
    let preparation = Preparation(wrapper, url: url, isLocal: false)
    try await waitFor("HTTP source preparation did not finish") { preparation.result != nil }
    guard case .success = preparation.result, events.preparedCount == 1,
      native.currentItem?.status == .readyToPlay
    else {
      throw Failure.message(
        "HTTP source failed to prepare: \(String(describing: preparation.result))")
    }
    await wrapper.dispose()
  }

  @MainActor static func testNextPlayerStartsOnCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.wav")
    let secondURL = root.appendingPathComponent("second.wav")
    try writeSilence(to: firstURL)
    try writeSilence(to: secondURL)

    let plugin = AudioplayersDarwinPlugin()
    func makePlayer() -> (WrappedMediaPlayer, AudioPlayersStreamHandler, AVPlayer) {
      let native = AVPlayer()
      native.isMuted = true
      let events = AudioPlayersStreamHandler()
      return (
        WrappedMediaPlayer(reference: plugin, eventHandler: events, player: native), events, native
      )
    }
    let (current, currentEvents, currentNative) = makePlayer()
    let (following, followingEvents, _) = makePlayer()
    try await current.setSourceUrl(url: firstURL.path, isLocal: true)
    try await following.setSourceUrl(url: secondURL.path, isLocal: true)
    current.next = following
    guard current.next === following, !following.isPlaying else {
      throw Failure.message("Linking started the next player")
    }

    // A new source drops the link.
    try await current.setSourceUrl(url: secondURL.path, isLocal: true)
    guard current.next == nil else {
      throw Failure.message("A new source kept the link to the next player")
    }
    try await current.setSourceUrl(url: firstURL.path, isLocal: true)
    current.next = following
    current.resume()
    NotificationCenter.default.post(
      name: .AVPlayerItemDidPlayToEndTime, object: currentNative.currentItem)
    try await waitFor("The next player did not start as the current one completed") {
      following.isPlaying && currentEvents.completedCount == 1
    }
    guard current.next == nil, followingEvents.completedCount == 0 else {
      throw Failure.message("Completion kept the link or completed the next player")
    }
    await current.dispose()
    await following.dispose()
  }

  @MainActor static func testRadioEqualizer() async throws {
    guard let address = ProcessInfo.processInfo.environment["TEST_RADIO_HLS"] else { return }
    if #available(macOS 27.0, *) {
      let native = AVPlayer()
      let wrapper = WrappedMediaPlayer(reference: AudioplayersDarwinPlugin(),
        eventHandler: AudioPlayersStreamHandler(), player: native)
      defer { Task { @MainActor in await wrapper.dispose() } }
      wrapper.setBufferingPolicy(["minimumSeconds": 0.35, "forwardSeconds": 4.0])
      try await wrapper.setSourceUrl(url: address, isLocal: false)
      let frequencies: [Double] = [60, 250, 1000, 4000, 16000]
      let gains: [Double] = [0, 0, 0, 0, 0]
      try await wrapper.setEqualizer(["enabled": true, "frequencies": frequencies,
        "gains": gains, "inputGain": -12.0, "limiter": false])
      wrapper.resume()
      try await waitFor("HLS decoded PCM never reached the equalizer") {
        (wrapper.equalizerDiagnostics()["processedFrames"] as? Int64 ?? 0) >= 22050
      }
      let stats = wrapper.equalizerDiagnostics()
      guard let input = stats["inputRms"] as? Double, let output = stats["outputRms"] as? Double,
        input > 0, output / input > 0.20, output / input < 0.35 else {
        throw Failure.message("HLS equalizer gain was not applied to actual audio: \(stats)")
      }
      let beforeFrames = stats["processedFrames"] as! Int64
      try await wrapper.setEqualizer(["enabled": true, "frequencies": frequencies,
        "gains": gains, "inputGain": 0.0, "limiter": false])
      try await waitFor("Live EQ update stopped processing") {
        (wrapper.equalizerDiagnostics()["processedFrames"] as? Int64 ?? 0) >= beforeFrames + 22050
      }
      guard (wrapper.equalizerDiagnostics()["outputRms"] as! Double) > output else {
        throw Failure.message("Live preset change did not affect radio samples")
      }
      print("PASS: real HLS PCM passes through EQ and live gain updates")
      await wrapper.dispose()
    } else { print("SKIP: real HLS mixed tap requires macOS 27") }
  }

  @MainActor static func testSeekCompletionBelongsToCurrentSource() async throws {
    for outcome in ["replacement", "disposal", "cancellation", "success"] {
      let native = DeferredPlayer()
      let events = AudioPlayersStreamHandler()
      let wrapper = WrappedMediaPlayer(
        reference: AudioplayersDarwinPlugin(), eventHandler: events, player: native)
      let item = DeferredSeekItem(url: URL(fileURLWithPath: "/seek.wav"))
      native.replaceCurrentItem(with: item)
      var finished = false
      Task { @MainActor in
        await wrapper.seek(time: toCMTime(millis: 100))
        finished = true
      }
      try await waitFor("Seek did not start") { item.pendingSeek != nil }
      if outcome == "replacement" {
        native.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/replacement.wav")))
      } else if outcome == "disposal" {
        await wrapper.dispose()
      }
      let pauses = native.pauseCount
      item.pendingSeek?(outcome != "cancellation")
      item.pendingSeek = nil
      try await waitFor("Seek did not finish") { finished }
      let expected = outcome == "success" ? 1 : 0
      guard events.seekCompletedCount == expected, native.pauseCount == pauses + expected else {
        throw Failure.message("A \(outcome) seek emitted a stale event or paused another source")
      }
      await wrapper.dispose()
    }
  }

  @MainActor static func testTimedMetadata() throws {
    let metadata = StreamMetadata()
    func field(_ identifier: AVMetadataIdentifier, _ text: String) -> AVMetadataItem {
      let item = AVMutableMetadataItem()
      item.identifier = identifier
      item.value = text as NSString
      return item
    }
    let first = AVTimedMetadataGroup(items: [
      field(.commonIdentifierTitle, "First"), field(.commonIdentifierArtist, "Artist"),
      field(.commonIdentifierAlbumName, "Album")],
      timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)))
    metadata.metadataOutput(metadata.output, didOutputTimedMetadataGroups: [first], from: nil)
    guard metadata.values["title"] == "First", metadata.values["artist"] == "Artist",
      metadata.values["album"] == "Album" else { throw Failure.message("Timed metadata was not decoded") }
    let next = AVTimedMetadataGroup(items: [field(.commonIdentifierTitle, "Next")],
      timeRange: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: .positiveInfinity))
    metadata.metadataOutput(metadata.output, didOutputTimedMetadataGroups: [next], from: nil)
    guard metadata.values == ["title": "Next"] else { throw Failure.message("A new broadcast track retained old tags") }
    let empty = AVTimedMetadataGroup(items: [field(.commonIdentifierTitle, "")],
      timeRange: CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: .positiveInfinity))
    metadata.metadataOutput(metadata.output, didOutputTimedMetadataGroups: [empty], from: nil)
    guard metadata.values == ["title": ""] else { throw Failure.message("Empty broadcast title did not restore station fallback") }
    print("PASS: native timed metadata updates atomically and clears stale album/artist")
  }

  @MainActor static func main() async {
    do {
      try testTimedMetadata()
      try testSourceDiagnostics()
      print("PASS: source errors retain native causes without leaking private userInfo")
      let native = DeferredPlayer()
      let events = AudioPlayersStreamHandler()
      let wrapper = WrappedMediaPlayer(
        reference: AudioplayersDarwinPlugin(), eventHandler: events, player: native)

      let first = Preparation(wrapper, url: "/first.wav")
      try await waitFor("First source was not installed") { native.currentItem != nil }
      let firstItem = native.currentItem
      let replacement = Preparation(wrapper, url: "/second.wav")
      try await waitFor("Replacement source was not installed") {
        native.currentItem != nil && native.currentItem !== firstItem
      }
      let replacementItem = native.currentItem
      try await requireCancelled(first)
      guard native.currentItem === replacementItem else {
        throw Failure.message("Finishing the old source changed its replacement")
      }

      await wrapper.dispose()
      try await requireCancelled(replacement)
      guard native.currentItem == nil, events.preparedCount == 0 else {
        throw Failure.message("Disposal left a source or emitted a prepared event")
      }
      print("PASS: replacing and disposing loading sources completes cancelled preparation")
      let stalled = DeferredPlayer()
      let timeoutEvents = AudioPlayersStreamHandler()
      let bounded = WrappedMediaPlayer(reference: AudioplayersDarwinPlugin(), eventHandler: timeoutEvents,
        player: stalled, preparationTimeout: 0.05)
      let unknown = Preparation(bounded, url: "/stalled.wav")
      try await requireCancelled(unknown)
      guard stalled.currentItem == nil, timeoutEvents.preparedCount == 0 else {
        throw Failure.message("An unknown item did not terminate safely after its deadline")
      }
      await bounded.dispose()
      print("PASS: unknown AVPlayerItem preparation has a bounded deadline")

      try await testNativePreparationAndStaleCompletion()
      print("PASS: native preparation succeeds or fails once, and ignores old completion events")
      try await testRadioEqualizer()
      try await testNextPlayerStartsOnCompletion()
      print("PASS: a linked next player starts as the current one completes")
      try await testSeekCompletionBelongsToCurrentSource()
      print("PASS: replaced, disposed and cancelled seeks cannot affect the current source")
      for url in CommandLine.arguments.dropFirst() {
        try await testNetworkPreparation(url)
        print("PASS: native AVPlayer prepares the HTTP proxy source")
      }
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
