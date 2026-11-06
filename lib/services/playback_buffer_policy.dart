import 'dart:math' as math;

/// Native forward buffering is a preference, not a promise of downloaded time.
class PlaybackBufferPolicy {
  const PlaybackBufferPolicy({
    this.minimumSeconds = 0.35,
    this.forwardSeconds = 4,
    this.prepareTimeoutSeconds = 30,
  });
  final double minimumSeconds, forwardSeconds, prepareTimeoutSeconds;
  Map<String, double> toNative() => {
    'minimumSeconds': minimumSeconds,
    'forwardSeconds': forwardSeconds,
    'prepareTimeoutSeconds': prepareTimeoutSeconds,
  };
}

/// Bounded, per-account observations; no URLs, authentication or audio is stored.
class PlaybackNetworkProfile {
  int samples = 0, stalls = 0;
  double firstByteSeconds = 0, bytesPerSecond = 0;
  void observe({
    required Duration firstByte,
    required int bytes,
    required Duration transfer,
  }) {
    final latency = firstByte.inMicroseconds / 1000000;
    final rate = bytes / math.max(0.001, transfer.inMicroseconds / 1000000);
    firstByteSeconds = samples == 0
        ? latency
        : firstByteSeconds * 0.75 + latency * 0.25;
    bytesPerSecond = samples == 0 ? rate : bytesPerSecond * 0.75 + rate * 0.25;
    samples++;
  }

  void stalled() => stalls = math.min(6, stalls + 1);
  PlaybackBufferPolicy get policy => policyFor(null);
  PlaybackBufferPolicy policyFor(int? bitrate) {
    final encodedBytesPerSecond = ((bitrate ?? 256) * 1000 / 8).clamp(
      8000,
      768000,
    );
    final throughputRisk = samples >= 2 && bytesPerSecond > 0
        ? (encodedBytesPerSecond * 1.5 / bytesPerSecond - 1).clamp(0.0, 1.0)
        : 0.0;
    final minimum =
        (0.35 + firstByteSeconds * 1.5 + stalls * 0.4 + throughputRisk).clamp(
          0.35,
          3.0,
        );
    return PlaybackBufferPolicy(
      minimumSeconds: minimum,
      forwardSeconds: (minimum * 4).clamp(4.0, 12.0),
      prepareTimeoutSeconds: (30 + firstByteSeconds * 3).clamp(30.0, 45.0),
    );
  }

  int probeBytes(int? bitrate) {
    if (samples == 0 || (firstByteSeconds < 0.25 && stalls == 0)) return 4096;
    final rate = ((bitrate ?? 256) * 1000 / 8).clamp(8000, 768000);
    return (rate * policyFor(bitrate).minimumSeconds).ceil().clamp(4096, 65536);
  }
}
