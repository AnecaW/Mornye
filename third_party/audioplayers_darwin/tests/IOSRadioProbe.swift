import AVFoundation
import SwiftUI
import UIKit

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
  @State private var running = false
  @State private var results = [[String: Any]]()
  var body: some Scene {
    WindowGroup {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Mornye EQ-test").font(.largeTitle.bold())
          Text("Verbind eerst je Bluetooth-hoofdtelefoon. De test gebruikt alleen meegeleverde geluiden en duurt ongeveer anderhalve minuut.")
          Text("iOS \(UIDevice.current.systemVersion)").font(.caption)
          Text("Uitvoer: " + AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portName }.joined(separator: ", ")).font(.caption)
          Button(running ? "Test loopt…" : "Start audiotest") {
            Task { await start() }
          }.buttonStyle(.borderedProminent).disabled(running)
          if !results.isEmpty {
            ForEach(results.indices, id: \.self) { index in
              let row = results[index]
              Label(Self.label(row), systemImage: Self.passed(row) ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(Self.passed(row) ? Color.green : Color.red)
            }
            Button("Resultaten kopiëren") {
              UIPasteboard.general.string = Self.encoded(results)
            }.buttonStyle(.bordered)
            Text("Groen betekent dat de EQ echt audiosamples verwerkte en de ingestelde versterking toepaste.").font(.caption)
          }
        }.padding(24)
      }.task {
        #if targetEnvironment(simulator)
        guard !started else { return }
        await start()
        exit(0)
        #endif
      }
    }
  }

  private func start() async {
    started = true
    running = true
    results = await Self.run()
    running = false
  }

  static func passed(_ row: [String: Any]) -> Bool {
    guard let stats = row["stats"] as? [String: Any],
      let frames = stats["processedFrames"] as? Int64,
      let input = stats["inputRms"] as? Double,
      let output = stats["outputRms"] as? Double, input > 0 else { return false }
    return frames >= 22050 && (0.20...0.35).contains(output / input)
  }

  static func label(_ row: [String: Any]) -> String {
    let key = row["case"] as? String ?? "audio-session"
    return ["wav-control": "WAV-bestand met EQ", "flac-control": "FLAC-bestand met EQ",
      "mp3-control": "MP3-bestand met EQ", "flac-http": "FLAC-stream met EQ",
      "mp3-http": "MP3-stream met EQ", "hls-44100": "HLS-radio met EQ",
      "hls-24000": "HLS-radio lage bitrate", "hls-cmaf": "HLS-radio CMAF",
      "concrete-track-wav": "Klassieke audiotrack-controle",
      "concrete-track-high/live.m3u8": "HLS met concrete audiotrack",
      "concrete-track-low/live.m3u8": "HLS lage bitrate met audiotrack",
      "concrete-track-cmaf/live.m3u8": "HLS CMAF met audiotrack",
      "before-association-high/live.m3u8": "HLS vooraf aansluiten",
      "before-association-low/live.m3u8": "HLS lage bitrate vooraf aansluiten"][key] ?? "Audio voorbereiden"
  }

  static func encoded(_ results: [[String: Any]]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  static func run() async -> [[String: Any]] {
    var results = [[String: Any]]()
    let session = AVAudioSession.sharedInstance()
    let server = ProbeFixtureServer(root: Bundle.main.resourceURL!)
    defer { server.stop() }
    do {
      let port = try await server.start()
      let base = "http://127.0.0.1:\(port)"
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
      for (name, path) in [("wav-control", "tone.wav"),
        ("flac-control", "tone.flac"), ("mp3-control", "tone.mp3"),
        ("flac-http", "tone.flac"), ("mp3-http", "tone.mp3"),
        ("hls-44100", "high/live.m3u8"), ("hls-24000", "low/live.m3u8"),
        ("hls-cmaf", "cmaf/live.m3u8")] {
        let native = AVPlayer()
        let wrapper = WrappedMediaPlayer(reference: AudioplayersDarwinPlugin(),
          eventHandler: AudioPlayersStreamHandler(), player: native,
          preparationTimeout: 10)
        wrapper.releaseMode = .stop
        var result: [String: Any] = ["case": name,
          "routeRate": session.sampleRate, "routeChannels": session.outputNumberOfChannels]
        do {
          let local = name.hasSuffix("-control")
          let address = local ? Bundle.main.url(forResource: "tone", withExtension: String(path.split(separator: ".").last!))!.path
            : "\(base)/\(path)"
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

      // HLS can expose a concrete AVAssetTrack on newer systems. Compare that
      // real track directly with the special mixed-stream ID on the same data.
      for path in ["high/live.m3u8", "low/live.m3u8", "cmaf/live.m3u8"] {
        let native = AVPlayer()
        let wrapper = WrappedMediaPlayer(reference: AudioplayersDarwinPlugin(),
          eventHandler: AudioPlayersStreamHandler(), player: native, preparationTimeout: 10)
        wrapper.releaseMode = .stop
        var result: [String: Any] = ["case": "concrete-track-\(path)"]
        do {
          try await wrapper.setSourceUrl(url: "\(base)/\(path)", isLocal: false)
          let item = native.currentItem!
          if let track = item.tracks.compactMap({ $0.assetTrack }).first(where: { $0.mediaType == .audio }) {
            let processor = EqualizerAudioTap()
            processor.dsp.configure(["enabled": true,
              "frequencies": [60.0, 250.0, 1000.0, 4000.0, 16000.0],
              "gains": [0.0, 0.0, 0.0, 0.0, 0.0], "inputGain": -12.0, "limiter": false])
            try await EqualizerAudioTap.attach(to: item, processor: processor, track: track)
            wrapper.resume()
            for _ in 0..<160 {
              if (processor.diagnostics()["processedFrames"] as? Int64 ?? 0) >= 22050 { break }
              try await Task.sleep(nanoseconds: 50_000_000)
            }
            result["stats"] = processor.diagnostics()
            result["mixTrack"] = item.audioMix?.inputParameters.first?.trackID
            result["status"] = item.status.rawValue
          } else { result["trackMissing"] = true }
        } catch { result["diagnostic"] = String(describing: error) }
        results.append(result)
        await wrapper.dispose()
      }

      // Compare the identical processor/format before AVPlayer association.
      // Only attachment timing differs from the wrapper's ready-item path.
      for path in ["high/live.m3u8", "low/live.m3u8"] {
        let native = AVPlayer()
        let item = AVPlayerItem(url: URL(string: "\(base)/\(path)")!)
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
    results = results.map { row in
      var result = row
      result["iOS"] = UIDevice.current.systemVersion
      result["outputTypes"] = session.currentRoute.outputs.map { $0.portType.rawValue }
      return result
    }
    let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("native-audio-results.json")
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output, options: .atomic)
      print(String(decoding: data, as: UTF8.self))
    }
    return results
  }
}
