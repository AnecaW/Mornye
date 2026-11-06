import AVFoundation
import SwiftUI

// A real iOS application with no Flutter channel/session code. This separates
// renderer/tap behavior from the plugin boundary and includes a WAV control.
@MainActor final class AudioplayersDarwinPlugin {
  func controlAudioSession() {}
}
final class AudioPlayersStreamHandler {
  func onSeekComplete() {}
  func onPrepared(isPrepared: Bool) {}
  func onLog(message: String) {}
  func onDuration(millis: Int) {}
  func onComplete() {}
  func dispose() {}
  func onError(code: String, message: String, details: String) {}
}

@main @MainActor struct IOSRadioProbe: App {
  @State private var started = false
  var body: some Scene {
    WindowGroup {
      Text("Native audio diagnostic").task {
        guard !started else { return }
        started = true
        await Self.run()
      }
    }
  }

  static func run() async {
    var results = [[String: Any]]()
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
      for (name, path) in [("wav-control", "tone.wav"),
        ("hls-44100", "high/live.m3u8"), ("hls-24000", "low/live.m3u8")] {
        let native = AVPlayer()
        let wrapper = WrappedMediaPlayer(reference: AudioplayersDarwinPlugin(),
          eventHandler: AudioPlayersStreamHandler(), player: native,
          preparationTimeout: 10)
        wrapper.releaseMode = .stop
        var result: [String: Any] = ["case": name,
          "routeRate": session.sampleRate, "routeChannels": session.outputNumberOfChannels]
        do {
          try await wrapper.setSourceUrl(url: "http://127.0.0.1:18762/\(path)", isLocal: false)
          try await wrapper.setEqualizer(["enabled": true,
            "frequencies": [60.0, 250.0, 1000.0, 4000.0, 16000.0],
            "gains": [0.0, 0.0, 0.0, 0.0, 0.0], "inputGain": -12.0,
            "limiter": false])
          wrapper.resume()
          for _ in 0..<160 {
            if (wrapper.equalizerDiagnostics()["processedFrames"] as? Int64 ?? 0) >= 22050 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
          }
          result["stats"] = wrapper.equalizerDiagnostics()
          result["position"] = wrapper.getCurrentPosition()
          result["status"] = native.currentItem?.status.rawValue
          result["mixTrack"] = native.currentItem?.audioMix?.inputParameters.first?.trackID
          result["hasTap"] = native.currentItem?.audioMix?.inputParameters.first?.audioTapProcessor != nil
        } catch {
          result["errorType"] = String(describing: type(of: error))
        }
        results.append(result)
        await wrapper.dispose()
      }
    } catch { results.append(["sessionErrorType": String(describing: type(of: error))]) }
    let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("native-audio-results.json")
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output, options: .atomic)
      print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
  }
}
