import 'dart:async';
import 'dart:math';

import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_diagnostics.dart';
import 'package:mornye/services/streaming/stream_types.dart';

/// Recent throughput and failure samples for the user's server.
class ConnectionHealth {
  ConnectionHealth({this.window = 8});

  final int window;
  final List<double> _throughput = [];
  int _successes = 0;
  int _failures = 0;

  double get throughputBytesPerSecond {
    if (_throughput.isEmpty) return 0;
    var total = 0.0;
    for (final sample in _throughput) {
      total += sample;
    }
    return total / _throughput.length;
  }

  double get failureRate {
    final total = _successes + _failures;
    return total == 0 ? 0 : _failures / total;
  }

  bool get degraded => failureRate >= 0.4 && _failures >= 2;

  void noteThroughput(int bytes, Duration elapsed) {
    if (bytes <= 0 || elapsed <= Duration.zero) return;
    final rate = bytes * 1000 / elapsed.inMilliseconds;
    if (!rate.isFinite || rate <= 0) return;
    _throughput.add(rate);
    while (_throughput.length > window) {
      _throughput.removeAt(0);
    }
  }

  void noteSuccess() => _successes++;

  void noteFailure() => _failures++;

  void reset() {
    _throughput.clear();
    _successes = 0;
    _failures = 0;
  }
}

/// Opens authenticated range reads, retries transient failures with
/// exponential backoff, and refuses to return a response whose generation has
/// been superseded.
class StreamManager {
  StreamManager({
    required this.diagnostics,
    this.requestTimeout = const Duration(seconds: 20),
    this.maxAttempts = 4,
    this.initialBackoff = const Duration(milliseconds: 400),
    this.maxBackoff = const Duration(seconds: 8),
    Random? random,
    this.onAuthenticationFailure,
  }) : _random = random ?? Random();

  final StreamDiagnostics diagnostics;
  final Duration requestTimeout;
  final int maxAttempts;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final Random _random;

  /// Called once per stream when the server rejects the credentials, so the
  /// caller can refresh a session token before the single auth retry.
  final Future<void> Function()? onAuthenticationFailure;

  final health = ConnectionHealth();
  int _active = 0;
  bool _disposed = false;

  int get activeRequests => _active;

  /// Opens [start]..[end] for [generation]. Retries transient network, timeout,
  /// 408/429 and 5xx failures. A permanent failure throws immediately; an
  /// obsolete generation throws a cancelled [StreamFailure].
  Future<StreamResponse> open({
    required StreamOpen opener,
    required PlaybackGeneration generation,
    required GenerationManager generations,
    int start = 0,
    int? end,
    String purpose = 'audio',
  }) async {
    if (_disposed) {
      throw const StreamFailure(StreamFailureKind.cancelled, retryable: false);
    }
    if (!generations.isCurrent(generation)) {
      diagnostics.noteCancellation(generation);
      throw const StreamFailure(
        StreamFailureKind.cancelled,
        retryable: false,
        detail: 'superseded',
      );
    }
    // Reuse the selection's timeline (a cache hit may have started one) so
    // retries and cancellations are recorded before the first successful
    // connection, and TTFA is measured from the selection, not the connect.
    final existing = diagnostics.current;
    final timeline = existing != null && existing.generation.id == generation.id
        ? existing
        : diagnostics.begin(generation, label: purpose, cacheHit: false);
    var authRetried = false;
    StreamFailure? lastFailure;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!generations.isCurrent(generation)) {
        diagnostics.noteCancellation(generation);
        throw const StreamFailure(
          StreamFailureKind.cancelled,
          retryable: false,
          detail: 'superseded',
        );
      }
      _active++;
      final stopwatch = Stopwatch()..start();
      try {
        final response = await opener(start, end).timeout(
          requestTimeout,
          onTimeout: () => throw TimeoutException(
            'Stream request timed out',
            requestTimeout,
          ),
        );
        stopwatch.stop();
        if (!generations.isCurrent(generation)) {
          await _discard(response);
          diagnostics.noteCancellation(generation);
          throw const StreamFailure(
            StreamFailureKind.cancelled,
            retryable: false,
            detail: 'superseded',
          );
        }
        if (response.statusCode >= 400) {
          throw StreamFailure.classifyStatus(response.statusCode);
        }
        health.noteSuccess();
        diagnostics.markConnected(timeline);
        return response;
      } on Object catch (error) {
        stopwatch.stop();
        final failure = StreamFailure.classify(error);
        if (failure.kind == StreamFailureKind.cancelled ||
            !generations.isCurrent(generation)) {
          diagnostics.noteCancellation(generation);
          throw failure.asCancelled();
        }
        lastFailure = failure;
        health.noteFailure();
        if (failure.kind == StreamFailureKind.authentication && !authRetried) {
          authRetried = true;
          try {
            await onAuthenticationFailure?.call();
          } on Object {
            // The retry below reports the failure if credentials are still bad.
          }
        } else if (!failure.retryable || attempt == maxAttempts) {
          throw failure;
        }
        diagnostics.noteRetry(
          generation,
          reason:
              '${failure.kind.name}'
              '${failure.statusCode == null ? '' : '/${failure.statusCode}'}',
        );
        final backoff = _backoff(attempt);
        final stillWanted = await _waitOrCancel(
          backoff,
          generation,
          generations,
        );
        if (!stillWanted) {
          diagnostics.noteCancellation(generation);
          throw const StreamFailure(
            StreamFailureKind.cancelled,
            retryable: false,
            detail: 'superseded',
          );
        }
      } finally {
        _active--;
      }
    }
    throw lastFailure ??
        const StreamFailure(
          StreamFailureKind.network,
          retryable: true,
          detail: 'retry limit reached',
        );
  }

  /// Records throughput for a download as bytes arrive.
  void noteThroughput(int bytes, Duration elapsed) =>
      health.noteThroughput(bytes, elapsed);

  /// Waits for the retry backoff after attempt [attempt]. Returns false when
  /// the generation was superseded and the caller must stop.
  Future<bool> waitForRetry({
    required int attempt,
    required PlaybackGeneration generation,
    required GenerationManager generations,
  }) => _waitOrCancel(_backoff(attempt), generation, generations);

  Duration _backoff(int attempt) {
    final exponential = initialBackoff.inMilliseconds * (1 << (attempt - 1));
    final capped = min(exponential, maxBackoff.inMilliseconds);
    final jittered = capped * (0.7 + _random.nextDouble() * 0.6);
    return Duration(milliseconds: jittered.round());
  }

  Future<bool> _waitOrCancel(
    Duration delay,
    PlaybackGeneration generation,
    GenerationManager generations,
  ) {
    if (!generations.isCurrent(generation)) return Future.value(false);
    final completer = Completer<bool>();
    final timer = Timer(delay, () {
      if (!completer.isCompleted) {
        completer.complete(generations.isCurrent(generation));
      }
    });
    late final StreamSubscription<PlaybackGeneration> subscription;
    subscription = generations.changes.listen((_) {
      if (!completer.isCompleted) completer.complete(false);
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      unawaited(subscription.cancel());
    });
  }

  static Future<void> _discard(StreamResponse response) async {
    try {
      await response.bytes.listen((_) {}).cancel();
    } on Object {
      // The server may have closed the response already.
    }
    try {
      await response.close();
    } on Object {
      // Closing an already closed response is harmless.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
  }
}
