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
          let local = name == "wav-control"
          let address = local ? Bundle.main.url(forResource: "tone", withExtension: "wav")!.path
            : "http://127.0.0.1:18762/\(path)"
          try await wrapper.setSourceUrl(url: address, isLocal: local)
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
          result["diagnostic"] = String(describing: error)
        }
        results.append(result)
        await wrapper.dispose()
      }
      // A concrete-track WAV control distinguishes a mixed-tap problem from
      // an iOS simulator that is not rendering audio through any tap.
      let localItem = AVPlayerItem(url: Bundle.main.url(forResource: "tone", withExtension: "wav")!)
      let localProcessor = EqualizerAudioTap()
      localProcessor.dsp.configure(["enabled": true,
        "frequencies": [60.0, 250.0, 1000.0, 4000.0, 16000.0],
        "gains": [0.0, 0.0, 0.0, 0.0, 0.0], "inputGain": -12.0, "limiter": false])
      let tracks = try await localItem.asset.loadTracks(withMediaType: .audio)
      let localPlayer = AVPlayer()
      var localResult: [String: Any] = ["case": "concrete-track-wav"]
      if let track = tracks.first {
        try await EqualizerAudioTap.attach(to: localItem, processor: localProcessor, track: track)
        localPlayer.replaceCurrentItem(with: localItem)
        localPlayer.play()
        for _ in 0..<160 {
          if (localProcessor.diagnostics()["processedFrames"] as? Int64 ?? 0) >= 22050 { break }
          try await Task.sleep(nanoseconds: 50_000_000)
        }
        localResult["stats"] = localProcessor.diagnostics()
        localResult["status"] = localItem.status.rawValue
        localResult["mixTrack"] = localItem.audioMix?.inputParameters.first?.trackID
        localPlayer.pause()
        localPlayer.replaceCurrentItem(with: nil)
      }
      results.append(localResult)

      // Compare the identical processor/format before AVPlayer association.
      // Only attachment timing differs from the wrapper's ready-item path.
      for path in ["high/live.m3u8", "low/live.m3u8"] {
        let native = AVPlayer()
        let item = AVPlayerItem(url: URL(string: "http://127.0.0.1:18762/\(path)")!)
        item.audioTimePitchAlgorithm = .timeDomain
        let processor = EqualizerAudioTap()
        processor.dsp.configure(["enabled": true,
          "frequencies": [60.0, 250.0, 1000.0, 4000.0, 16000.0],
          "gains": [0.0, 0.0, 0.0, 0.0, 0.0], "inputGain": -12.0,
          "limiter": false])
        var result: [String: Any] = ["case": "before-association-\(path)"]
        do {
          try await EqualizerAudioTap.attach(to: item, processor: processor)
          native.replaceCurrentItem(with: item)
          native.play()
          for _ in 0..<160 {
            if (processor.diagnostics()["processedFrames"] as? Int64 ?? 0) >= 22050 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
          }
          result["stats"] = processor.diagnostics()
          result["status"] = item.status.rawValue
          result["mixTrack"] = item.audioMix?.inputParameters.first?.trackID
          result["hasTap"] = item.audioMix?.inputParameters.first?.audioTapProcessor != nil
        } catch { result["diagnostic"] = String(describing: error) }
        results.append(result)
        native.pause()
        native.replaceCurrentItem(with: nil)
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
