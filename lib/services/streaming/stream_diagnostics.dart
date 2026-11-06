import 'dart:async';

import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_types.dart';

/// Timing and health facts for one selection, from the Play action to audio
/// output. It holds no URL, header or credential.
class StreamTimeline {
  StreamTimeline({
    required this.generation,
    required this.label,
    required this.cacheHit,
    required this.startedAt,
  });

  final PlaybackGeneration generation;

  /// Credential-free short track label.
  final String label;
  final bool cacheHit;
  final DateTime startedAt;

  DateTime? connectedAt;
  DateTime? firstByteAt;
  DateTime? decoderReadyAt;
  DateTime? firstAudioAt;
  DateTime? finishedAt;
  int retries = 0;
  int cancellations = 0;
  int bytesDownloaded = 0;
  int bufferingEvents = 0;
  Duration bufferingTotal = Duration.zero;
  DateTime? _bufferingSince;
  bool cacheCompleted = false;
  bool integrityVerified = false;
  String? failure;

  /// Time to first audio: the primary playback performance metric.
  Duration? get timeToFirstAudio => firstAudioAt?.difference(startedAt);

  Duration? get connectionLatency => connectedAt?.difference(startedAt);

  Duration? get firstByteLatency => firstByteAt?.difference(startedAt);

  Duration? get decoderInitialization {
    final ready = decoderReadyAt;
    final first = firstByteAt;
    if (ready == null || first == null) return null;
    return ready.difference(first);
  }

  void beginBuffering(DateTime now) {
    if (_bufferingSince != null) return;
    _bufferingSince = now;
    bufferingEvents++;
  }

  void endBuffering(DateTime now) {
    final since = _bufferingSince;
    if (since == null) return;
    bufferingTotal += now.difference(since);
    _bufferingSince = null;
  }

  Map<String, dynamic> toJson() => {
    'generation': generation.id,
    'label': label,
    'cacheHit': cacheHit,
    'cacheCompleted': cacheCompleted,
    'integrityVerified': integrityVerified,
    'ttfaMs': timeToFirstAudio?.inMilliseconds,
    'connectMs': connectionLatency?.inMilliseconds,
    'firstByteMs': firstByteLatency?.inMilliseconds,
    'decoderInitMs': decoderInitialization?.inMilliseconds,
    'bytesDownloaded': bytesDownloaded,
    'retries': retries,
    'cancellations': cancellations,
    'bufferingEvents': bufferingEvents,
    'bufferingMs': bufferingTotal.inMilliseconds,
    if (failure != null) 'failure': failure,
  };
}

/// Aggregated playback-streaming metrics and a bounded history of recent
/// selections. Logs are opt-in through [onLog] and never contain secrets.
class StreamDiagnostics {
  StreamDiagnostics({
    DateTime Function()? clock,
    this.historyLimit = 20,
    this.onLog,
    this.slowFirstAudio = const Duration(seconds: 3),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final int historyLimit;
  final void Function(String message)? onLog;
  final Duration slowFirstAudio;

  final _history = <StreamTimeline>[];
  final _changes = StreamController<Map<String, dynamic>>.broadcast();
  StreamTimeline? _current;
  int _failedPlaybacks = 0;
  int _cacheHits = 0;
  int _cacheLookups = 0;
  int _recoveries = 0;
  int _totalRetries = 0;
  int _totalCancellations = 0;
  int _totalBufferingEvents = 0;
  Duration _totalBuffering = Duration.zero;
  Duration _totalPlayed = Duration.zero;

  StreamTimeline? get current => _current;
  List<Map<String, dynamic>> get history => [
    for (final timeline in _history) timeline.toJson(),
  ];

  /// Cache hit rate over selections that looked up the cache.
  double get cacheHitRate =>
      _cacheLookups == 0 ? 0 : _cacheHits / _cacheLookups;

  double get averageBufferingMilliseconds {
    if (_totalBufferingEvents == 0) return 0;
    return _totalBuffering.inMilliseconds / _totalBufferingEvents;
  }

  /// Rebuffering events per hour of actual playback.
  double get rebufferPerHour {
    final hours = _totalPlayed.inMilliseconds / 3600000;
    return hours <= 0 ? 0 : _totalBufferingEvents / hours;
  }

  int get failedPlaybacks => _failedPlaybacks;
  int get recoveries => _recoveries;
  int get totalRetries => _totalRetries;
  int get totalCancellations => _totalCancellations;

  Stream<Map<String, dynamic>> get changes => _changes.stream;

  static String safeLabel(String value) {
    if (value.isEmpty) return 'unknown';
    var hash = 2166136261;
    for (final code in value.codeUnits) {
      hash ^= code;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  StreamTimeline begin(
    PlaybackGeneration generation, {
    required String label,
    required bool cacheHit,
  }) {
    final timeline = StreamTimeline(
      generation: generation,
      label: safeLabel(label),
      cacheHit: cacheHit,
      startedAt: _clock(),
    );
    _current = timeline;
    _cacheLookups++;
    if (cacheHit) _cacheHits++;
    _history.add(timeline);
    while (_history.length > historyLimit) {
      _history.removeAt(0);
    }
    onLog?.call(
      'begin gen=${generation.id} label=${timeline.label} '
      'cache=${cacheHit ? 'hit' : 'miss'}',
    );
    _publish(timeline);
    return timeline;
  }

  void markConnected(StreamTimeline timeline) {
    if (!_isCurrent(timeline)) return;
    timeline.connectedAt ??= _clock();
  }

  void markFirstByte(StreamTimeline timeline) {
    if (!_isCurrent(timeline)) return;
    timeline.firstByteAt ??= _clock();
    markConnected(timeline);
  }

  void markDecoderReady(StreamTimeline timeline) {
    if (!_isCurrent(timeline)) return;
    timeline.decoderReadyAt ??= _clock();
    markFirstByte(timeline);
  }

  void markFirstAudio(StreamTimeline timeline) {
    if (!_isCurrent(timeline)) return;
    timeline.firstAudioAt ??= _clock();
    timeline.endBuffering(_clock());
    final ttfa = timeline.timeToFirstAudio;
    onLog?.call(
      'first audio gen=${timeline.generation.id} '
      'ttfa=${ttfa?.inMilliseconds}ms retries=${timeline.retries}',
    );
    if (ttfa != null && ttfa > slowFirstAudio) {
      onLog?.call(
        'slow first audio gen=${timeline.generation.id} '
        'ttfa=${ttfa.inMilliseconds}ms',
      );
    }
    _publish(timeline);
  }

  void markFinished(StreamTimeline timeline) {
    timeline.finishedAt ??= _clock();
    timeline.endBuffering(_clock());
    _publish(timeline);
  }

  void noteBytes(StreamTimeline timeline, int bytes) {
    if (bytes > 0) timeline.bytesDownloaded += bytes;
  }

  void noteRetry(PlaybackGeneration generation, {String? reason}) {
    final timeline = _matching(generation);
    if (timeline == null) return;
    timeline.retries++;
    _totalRetries++;
    onLog?.call(
      'retry gen=${generation.id} attempt=${timeline.retries}'
      '${reason == null ? '' : ' $reason'}',
    );
  }

  void noteRecovery(PlaybackGeneration generation) {
    final timeline = _matching(generation);
    if (timeline == null) return;
    _recoveries++;
    onLog?.call('recovered gen=${generation.id}');
    _publish(timeline);
  }

  void noteCancellation(PlaybackGeneration generation) {
    final timeline = _matching(generation);
    if (timeline == null) return;
    timeline.cancellations++;
    _totalCancellations++;
    onLog?.call('cancelled gen=${generation.id}');
  }

  void noteBufferingStart(PlaybackGeneration generation) {
    final timeline = _matching(generation);
    if (timeline == null) return;
    if (timeline._bufferingSince == null) {
      timeline.beginBuffering(_clock());
      _totalBufferingEvents++;
      onLog?.call('buffering gen=${generation.id}');
      _publish(timeline);
    }
  }

  void noteBufferingEnd(PlaybackGeneration generation, {Duration? played}) {
    final timeline = _matching(generation);
    if (timeline == null) return;
    final since = timeline._bufferingSince;
    timeline.endBuffering(_clock());
    if (since != null) {
      _totalBuffering += _clock().difference(since);
    }
    if (played != null && played > Duration.zero) _totalPlayed += played;
    _publish(timeline);
  }

  void notePlayed(PlaybackGeneration generation, Duration played) {
    if (played > Duration.zero) _totalPlayed += played;
    final timeline = _matching(generation);
    if (timeline != null) _publish(timeline);
  }

  void noteCacheCompleted(StreamTimeline timeline, {required bool verified}) {
    timeline.cacheCompleted = true;
    timeline.integrityVerified = verified;
    onLog?.call(
      'cache complete gen=${timeline.generation.id} '
      'verified=$verified bytes=${timeline.bytesDownloaded}',
    );
    _publish(timeline);
  }

  void noteFailure(PlaybackGeneration generation, StreamFailure failure) {
    final timeline = _matching(generation);
    if (timeline != null) {
      timeline.failure =
          '${failure.kind.name}'
          '${failure.statusCode == null ? '' : '/${failure.statusCode}'}';
    }
    _failedPlaybacks++;
    onLog?.call(
      'playback failed gen=${generation.id} '
      'kind=${failure.kind.name} status=${failure.statusCode ?? '-'}',
    );
    if (timeline != null) _publish(timeline);
  }

  void noteCacheCorruption(StreamTimeline timeline) {
    onLog?.call('cache invalid gen=${timeline.generation.id}');
    _publish(timeline);
  }

  Map<String, dynamic> snapshot() {
    final current = _current;
    return {
      'phase': current?.generation.id,
      'current': current?.toJson(),
      'cacheHitRate': cacheHitRate,
      'rebufferPerHour': rebufferPerHour,
      'averageBufferingMs': averageBufferingMilliseconds,
      'failedPlaybacks': _failedPlaybacks,
      'recoveries': _recoveries,
      'retries': _totalRetries,
      'cancellations': _totalCancellations,
      'playedMs': _totalPlayed.inMilliseconds,
    };
  }

  bool _isCurrent(StreamTimeline timeline) =>
      identical(_current, timeline) ||
      (_current?.generation.id == timeline.generation.id);

  StreamTimeline? _matching(PlaybackGeneration generation) {
    final current = _current;
    if (current != null && current.generation.id == generation.id) {
      return current;
    }
    for (final timeline in _history.reversed) {
      if (timeline.generation.id == generation.id) return timeline;
    }
    return null;
  }

  void _publish(StreamTimeline timeline) {
    if (!_changes.isClosed) _changes.add(timeline.toJson());
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
