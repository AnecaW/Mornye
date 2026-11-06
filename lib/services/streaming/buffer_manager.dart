import 'dart:math';

import 'package:mornye/services/streaming/playback_state_machine.dart';

/// How urgently more audio is needed.
enum BufferUrgency { healthy, watch, low, critical }

/// The current buffer decision: how much playable audio exists, the target this
/// connection should maintain, and whether playback should wait.
class BufferHealth {
  const BufferHealth({
    required this.phase,
    required this.buffered,
    required this.target,
    required this.lowWatermark,
    required this.urgency,
    required this.throughputBytesPerSecond,
    required this.bitrateBytesPerSecond,
  });

  final PlaybackPhase phase;
  final Duration buffered;
  final Duration target;
  final Duration lowWatermark;
  final BufferUrgency urgency;
  final double throughputBytesPerSecond;
  final int bitrateBytesPerSecond;

  bool get shouldWaitForMore =>
      urgency == BufferUrgency.critical ||
      (urgency == BufferUrgency.low && phase != PlaybackPhase.playing);

  double get fillRatio => target.inMilliseconds <= 0
      ? 0
      : buffered.inMilliseconds / target.inMilliseconds;
}

/// Adaptive buffer policy.
///
/// A fixed buffer assumption fails on a slow NAS: the target grows when the
/// connection is barely faster than the file and after a stall, and shrinks
/// when the connection is comfortable so playback starts sooner. Downloaded
/// source bytes and decoded output are tracked separately.
class BufferManager {
  BufferManager({
    this.minTarget = const Duration(seconds: 4),
    this.maxTarget = const Duration(seconds: 30),
    Duration? initialTarget,
    DateTime Function()? clock,
  }) : _target = initialTarget ?? minTarget,
       _clock = clock ?? DateTime.now;

  final Duration minTarget;
  final Duration maxTarget;
  final DateTime Function() _clock;
  Duration _target;
  int _stalls = 0;
  DateTime? _lastStall;
  DateTime? _steadySince;

  /// Source bytes written to cache or handed to the decoder for this track.
  int downloadedSourceBytes = 0;

  /// Source bytes the decoder has consumed, derived from playback position.
  int decodedSourceBytes = 0;

  /// Estimated decoded PCM bytes, kept separate from downloaded bytes.
  int decodedPcmBytes = 0;

  Duration get target => _target;
  int get stalls => _stalls;

  void reset() {
    _target = minTarget;
    _stalls = 0;
    _lastStall = null;
    _steadySince = null;
    downloadedSourceBytes = 0;
    decodedSourceBytes = 0;
    decodedPcmBytes = 0;
  }

  void onDownloaded(int sourceBytes) {
    if (sourceBytes > downloadedSourceBytes) {
      downloadedSourceBytes = sourceBytes;
    }
  }

  /// Records decoded output. [position] is the playback position; source bytes
  /// are estimated from the file bitrate while PCM bytes come from the format.
  void onDecoded({
    required Duration position,
    required int bitrateBytesPerSecond,
    int? sampleRate,
    int? channels,
    int? bitsPerSample,
  }) {
    decodedSourceBytes = max(
      0,
      (position.inMilliseconds * bitrateBytesPerSecond / 1000).round(),
    );
    if (sampleRate != null && channels != null && bitsPerSample != null) {
      decodedPcmBytes =
          position.inMilliseconds *
          sampleRate *
          channels *
          (bitsPerSample ~/ 8) ~/
          1000;
    }
    if (_lastStall != null &&
        _clock().difference(_lastStall!) > const Duration(seconds: 20) &&
        _stalls > 0) {
      // A long clean stretch earns back a shorter target.
      _stalls--;
      _lastStall = null;
    }
    _steadySince ??= _clock();
  }

  /// A playback interruption caused by an empty buffer.
  void onStall() {
    _stalls = min(_stalls + 1, 6);
    _lastStall = _clock();
    _steadySince = null;
  }

  void onSeek() {
    _steadySince = _clock();
  }

  /// The buffer target for the current connection quality.
  Duration targetFor({
    required int bitrateBytesPerSecond,
    required double throughputBytesPerSecond,
  }) {
    if (bitrateBytesPerSecond <= 0) return _target;
    final ratio = throughputBytesPerSecond / bitrateBytesPerSecond;
    var seconds = minTarget.inMilliseconds / 1000;
    if (ratio < 1.05) {
      seconds = 18;
    } else if (ratio < 1.15) {
      seconds = 12;
    } else if (ratio < 1.5) {
      seconds = 8;
    } else if (ratio < 3) {
      seconds = 5;
    } else {
      seconds = minTarget.inSeconds.toDouble();
    }
    seconds += _stalls * 2;
    final adaptive = Duration(milliseconds: (seconds * 1000).round());
    if (adaptive > _target) {
      _target = adaptive > maxTarget ? maxTarget : adaptive;
    } else if (adaptive < _target &&
        _steadySince != null &&
        _clock().difference(_steadySince!) > const Duration(seconds: 8)) {
      _target = adaptive < minTarget ? minTarget : adaptive;
    }
    return _target > maxTarget ? maxTarget : _target;
  }

  BufferHealth evaluate({
    required int bufferedAheadBytes,
    required int bitrateBytesPerSecond,
    required double throughputBytesPerSecond,
    required PlaybackPhase phase,
  }) {
    final target = targetFor(
      bitrateBytesPerSecond: bitrateBytesPerSecond,
      throughputBytesPerSecond: throughputBytesPerSecond,
    );
    final buffered = bitrateBytesPerSecond <= 0
        ? Duration.zero
        : Duration(
            milliseconds:
                (max(0, bufferedAheadBytes) * 1000 / bitrateBytesPerSecond)
                    .round(),
          );
    final low = Duration(milliseconds: (target.inMilliseconds * 0.35).round());
    final critical = Duration(
      milliseconds: (target.inMilliseconds * 0.12).round(),
    );
    final urgency = buffered <= critical
        ? BufferUrgency.critical
        : buffered <= low
        ? BufferUrgency.low
        : buffered < target
        ? BufferUrgency.watch
        : BufferUrgency.healthy;
    return BufferHealth(
      phase: phase,
      buffered: buffered,
      target: target,
      lowWatermark: low,
      urgency: urgency,
      throughputBytesPerSecond: throughputBytesPerSecond,
      bitrateBytesPerSecond: bitrateBytesPerSecond,
    );
  }

  /// Bytes downloaded but not yet consumed by the decoder.
  int get undecodedBytes => max(0, downloadedSourceBytes - decodedSourceBytes);
}
