import AVFoundation
import MediaToolbox

final class EqualizerAudioTap {
  let dsp = EqualizerDSP()
  private var format = AudioStreamBasicDescription()
  private var frame = [Double](repeating: 0, count: 8)
  private var processedFrames: Int64 = 0
  private var inputEnergy = 0.0, outputEnergy = 0.0

  func diagnostics() -> [String: Any] {
    dsp.lock.lock(); defer { dsp.lock.unlock() }
    let frames = Double(max(1, processedFrames))
    return ["processedFrames": processedFrames, "sampleRate": format.mSampleRate,
      "bits": format.mBitsPerChannel, "channels": format.mChannelsPerFrame,
      "inputRms": sqrt(inputEnergy / frames), "outputRms": sqrt(outputEnergy / frames)]
  }

  @MainActor static func attach(to item: AVPlayerItem, processor: EqualizerAudioTap,
    track explicitTrack: AVAssetTrack? = nil,
    shouldAttach: () -> Bool = { true }) async throws {
    let protected: Bool
    if #available(iOS 15.0, macOS 12.0, *) {
      protected = try await item.asset.load(.hasProtectedContent)
    } else { protected = item.asset.hasProtectedContent }
    guard !protected else { throw AudioPlayerError.error("Equalizer is unavailable for protected audio") }
    let input: AVMutableAudioMixInputParameters
    if let explicitTrack {
      input = AVMutableAudioMixInputParameters(track: explicitTrack)
    } else if #available(iOS 27.0, macOS 27.0, *) {
      // A stream's mix is not an AVAssetTrack. The mix ID supports live MP3,
      // AAC and HLS through the same decoded-PCM DSP as ordinary files.
      input = AVMutableAudioMixInputParameters()
      input.trackID = AVAudioMixInputParametersTrackID.mixID.rawValue
    } else {
      if (item.asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8" {
        throw AudioPlayerError.error("HLS equalizer processing requires iOS 27 or macOS 27")
      }
      let tracks: [AVAssetTrack]
      if #available(iOS 15.0, macOS 12.0, *) {
        tracks = try await item.asset.loadTracks(withMediaType: .audio)
      } else { tracks = item.asset.tracks(withMediaType: .audio) }
      guard let track = tracks.first ?? item.tracks.compactMap({ $0.assetTrack }).first(where: { $0.mediaType == .audio }) else {
        throw AudioPlayerError.error("Equalizer cannot access this stream's audio track on this system")
      }
      input = AVMutableAudioMixInputParameters(track: track)
    }
    let retained = Unmanaged.passRetained(processor)
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: retained.toOpaque(),
      init: { _, info, storage in storage.pointee = info },
      finalize: { tap in Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in
        let processor = Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        processor.dsp.prepare(sampleRate: format.pointee.mSampleRate)
        processor.dsp.lock.lock()
        processor.format = format.pointee
        processor.processedFrames = 0; processor.inputEnergy = 0; processor.outputEnergy = 0
        processor.dsp.lock.unlock()
      },
      unprepare: nil,
      process: { tap, count, _, buffers, framesOut, flagsOut in
        guard MTAudioProcessingTapGetSourceAudio(tap, count, buffers, flagsOut, nil, framesOut) == noErr else {
          framesOut.pointee = 0
          return
        }
        let processor = Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        processor.process(buffers, frames: Int(framesOut.pointee))
      })
    var tap: MTAudioProcessingTap?
    let status: OSStatus
    if #available(iOS 27.0, macOS 27.0, *), explicitTrack == nil {
      // The mixed HLS renderer may negotiate an output-device format that does
      // not expose LPCM to the tap on iOS. Request decoded floating-point PCM
      // at the active route's rate/channels; this changes no audio-session or
      // Bluetooth routing settings. The prepare callback remains authoritative.
      var preferredFormat: CMAudioFormatDescription?
      #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      let rate = session.sampleRate > 0 ? session.sampleRate : 48000
      let channels = AVAudioChannelCount(max(1, session.outputNumberOfChannels))
      preferredFormat = AVAudioFormat(standardFormatWithSampleRate: rate,
        channels: channels)?.formatDescription
      #endif
      status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, preferredFormat, &tap)
    } else {
      status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    }
    guard status == noErr, let tap else {
      retained.release()
      throw AudioPlayerError.error("Could not create equalizer audio tap: \(status)")
    }
    input.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [input]
    guard shouldAttach() else { return }
    item.audioMix = mix
  }

  private func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    guard dsp.lock.try() else { return }
    defer { dsp.lock.unlock() }
    let channels = Int(format.mChannelsPerFrame)
    guard dsp.enabled, channels > 0, channels <= 8,
      format.mFormatID == kAudioFormatLinearPCM else { return }
    let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let bits = Int(format.mBitsPerChannel)
    guard (floating && [32, 64].contains(bits)) || (!floating && [16, 32].contains(bits)) else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    for index in 0..<frames {
      var channel = 0
      for buffer in buffers {
        guard let data = buffer.mData else { return }
        for offset in 0..<Int(buffer.mNumberChannels) {
          let sample = index * Int(buffer.mNumberChannels) + offset
          if floating && bits == 32 { frame[channel] = Double(data.assumingMemoryBound(to: Float.self)[sample]) }
          else if floating { frame[channel] = data.assumingMemoryBound(to: Double.self)[sample] }
          else if bits == 16 { frame[channel] = Double(data.assumingMemoryBound(to: Int16.self)[sample]) / 32768 }
          else { frame[channel] = Double(data.assumingMemoryBound(to: Int32.self)[sample]) / 2147483648 }
          channel += 1
        }
      }
      inputEnergy += frame[0] * frame[0]
      dsp.processFrame(&frame, channels: channels)
      outputEnergy += frame[0] * frame[0]
      processedFrames += 1
      channel = 0
      for buffer in buffers {
        let data = buffer.mData!
        for offset in 0..<Int(buffer.mNumberChannels) {
          let sample = index * Int(buffer.mNumberChannels) + offset
          let value = frame[channel]
          if floating && bits == 32 { data.assumingMemoryBound(to: Float.self)[sample] = Float(value) }
          else if floating { data.assumingMemoryBound(to: Double.self)[sample] = value }
          else if bits == 16 { data.assumingMemoryBound(to: Int16.self)[sample] = Int16(max(-32768, min(32767, value * 32768))) }
          else { data.assumingMemoryBound(to: Int32.self)[sample] = Int32(max(-2147483648, min(2147483647, value * 2147483648))) }
          channel += 1
        }
      }
    }
  }
}
