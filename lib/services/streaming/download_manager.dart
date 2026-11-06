import 'dart:async';
import 'dart:math';

import 'package:mornye/services/streaming/audio_cache_manager.dart';
import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_manager.dart';
import 'package:mornye/services/streaming/stream_types.dart';

/// Relative importance of a download. The selected track is never queued here
/// (its session streams directly), so [foreground] is reserved for a caller
/// that must outrank every prefetch.
enum DownloadPriority { foreground, next, background }

/// The result of one scheduled download.
class DownloadOutcome {
  const DownloadOutcome({
    required this.bytes,
    required this.cached,
    this.completed = false,
    this.verified = false,
    this.failure,
  });

  final int bytes;

  /// The track was already fully cached when the job ran.
  final bool cached;
  final bool completed;
  final bool verified;
  final StreamFailure? failure;

  bool get succeeded => failure == null;

  const DownloadOutcome.cancelled()
    : bytes = 0,
      cached = false,
      completed = false,
      verified = false,
      failure = const StreamFailure(
        StreamFailureKind.cancelled,
        retryable: false,
      );
}

/// One progressive download request.
class DownloadJob {
  DownloadJob({
    required this.track,
    required this.opener,
    required this.generation,
    required this.priority,
    this.label = 'prefetch',
  });

  final StreamTrack track;
  final StreamOpen opener;
  final PlaybackGeneration generation;
  DownloadPriority priority;
  final String label;

  final completer = Completer<DownloadOutcome>();
  bool cancelled = false;
  int bytes = 0;
  int attempts = 0;
  StreamResponse? activeResponse;

  Future<DownloadOutcome> get done => completer.future;
}

/// Bounded, priority-aware background downloader.
///
/// Prefetching never competes with the active stream: the engine pauses it
/// while the listener's buffer is low and cancels it when a new track is
/// selected. Partially downloaded bytes stay in the cache and are resumed,
/// never discarded.
class DownloadManager {
  DownloadManager({
    required this.cache,
    required this.streams,
    required this.generations,
    this.maxConcurrent = 2,
    this.chunkBytes = 128 * 1024,
    this.maxStreamRestarts = 2,
    this.onLog,
  });

  final AudioCacheManager cache;
  final StreamManager streams;
  final GenerationManager generations;
  final void Function(String message)? onLog;
  final int maxConcurrent;
  final int chunkBytes;
  final int maxStreamRestarts;

  final _queue = <DownloadJob>[];
  final _byKey = <String, DownloadJob>{};
  int _running = 0;
  bool _paused = false;
  Completer<void>? _resume;
  bool _disposed = false;

  bool get isPaused => _paused;
  int get activeDownloads => _running;
  int get queuedDownloads => _queue.length;

  Set<String> get activeCacheKeys => {
    ..._queue.map((job) => job.track.cacheKey),
    for (final job in _byKey.values)
      if (!job.completer.isCompleted) job.track.cacheKey,
  };

  /// Schedules [job]; a job for an already queued track is shared instead of
  /// downloading the same bytes twice.
  Future<DownloadOutcome> schedule(DownloadJob job) {
    if (_disposed) return Future.value(const DownloadOutcome.cancelled());
    final existing = _byKey[job.track.cacheKey];
    if (existing != null && !existing.completer.isCompleted) {
      if (job.priority.index < existing.priority.index) {
        existing.priority = job.priority;
      }
      return existing.done;
    }
    _byKey[job.track.cacheKey] = job;
    _queue.add(job);
    _pump();
    return job.done;
  }

  /// Stops starting and reading prefetches. In-flight bytes already written
  /// stay valid.
  void pausePrefetch() {
    if (_disposed) return;
    _paused = true;
  }

  void resumePrefetch() {
    if (_disposed || !_paused) return;
    _paused = false;
    final resume = _resume;
    _resume = null;
    resume?.complete();
  }

  /// Cancels every queued and running prefetch, e.g. when the listener picks a
  /// track. The active streaming session is not affected.
  void cancelPrefetches() {
    for (final job in _queue.toList()) {
      _cancel(job);
    }
    for (final job in _byKey.values.toList()) {
      if (!job.completer.isCompleted) _cancel(job);
    }
  }

  void cancelAll() => cancelPrefetches();

  void _cancel(DownloadJob job) {
    if (job.cancelled) return;
    job.cancelled = true;
    _queue.remove(job);
    if (identical(_byKey[job.track.cacheKey], job)) {
      _byKey.remove(job.track.cacheKey);
    }
    final response = job.activeResponse;
    if (response != null) unawaited(response.close());
    if (!job.completer.isCompleted) {
      job.completer.complete(const DownloadOutcome.cancelled());
    }
  }

  void _pump() {
    if (_disposed) return;
    while (_running < maxConcurrent) {
      final job = _takeNext();
      if (job == null) return;
      _running++;
      unawaited(
        _run(job).whenComplete(() {
          _running--;
          if (identical(_byKey[job.track.cacheKey], job)) {
            _byKey.remove(job.track.cacheKey);
          }
          _pump();
        }),
      );
    }
  }

  DownloadJob? _takeNext() {
    _queue.removeWhere((job) => job.completer.isCompleted || job.cancelled);
    if (_queue.isEmpty) return null;
    var best = 0;
    for (var index = 1; index < _queue.length; index++) {
      if (_queue[index].priority.index < _queue[best].priority.index) {
        best = index;
      }
    }
    return _queue.removeAt(best);
  }

  Future<void> _run(DownloadJob job) async {
    try {
      final existing = await cache.open(job.track);
      if (existing != null && existing.isComplete) {
        _complete(
          job,
          DownloadOutcome(
            bytes: existing.cachedBytes,
            cached: true,
            completed: true,
            verified: true,
          ),
        );
        return;
      }
      final entry = existing ?? await cache.create(job.track);
      int? total = entry.totalSize ?? job.track.totalSize;
      var offset = entry.contiguousEndFrom(0);
      var bytes = 0;
      for (var restart = 0; ; restart++) {
        if (_stopped(job)) throw const _Cancelled();
        await _waitWhilePaused(job);
        final response = await streams.open(
          opener: job.opener,
          generation: job.generation,
          generations: generations,
          start: offset,
          purpose: job.label,
        );
        job.activeResponse = response;
        total ??= response.totalSize;
        if (total != null) entry.meta.totalSize ??= total;
        var restartNeeded = false;
        try {
          await for (final chunk in response.bytes) {
            if (_stopped(job)) throw const _Cancelled();
            await _waitWhilePaused(job);
            if (chunk.isEmpty) continue;
            final allowed = total == null
                ? chunk
                : (offset + chunk.length > total
                      ? chunk.sublist(0, max(0, total - offset))
                      : chunk);
            if (allowed.isEmpty) continue;
            await entry.write(offset, allowed);
            offset += allowed.length;
            bytes += allowed.length;
            job.bytes = bytes;
            if (total != null && offset >= total) break;
          }
        } on Object catch (error) {
          final failure = StreamFailure.classify(error);
          if (failure.kind == StreamFailureKind.cancelled || _stopped(job)) {
            throw const _Cancelled();
          }
          if (!failure.retryable || restart >= maxStreamRestarts) rethrow;
          restartNeeded = true;
          onLog?.call('Download restart ${restart + 1} (${failure.kind.name})');
          final resume = await streams.waitForRetry(
            attempt: restart + 1,
            generation: job.generation,
            generations: generations,
          );
          if (!resume) throw const _Cancelled();
        } finally {
          job.activeResponse = null;
          try {
            await response.close();
          } on Object {
            // The response may already be closed by cancellation.
          }
        }
        if (!restartNeeded) break;
      }
      total ??= offset;
      entry.meta.totalSize ??= total;
      final complete = await entry.finish();
      await entry.flush();
      if (complete) {
        onLog?.call('Cached prefetch verified (${job.bytes} bytes)');
      }
      _complete(
        job,
        DownloadOutcome(
          bytes: bytes,
          cached: false,
          completed: complete,
          verified: complete,
        ),
      );
    } on _Cancelled {
      if (!job.completer.isCompleted) {
        job.completer.complete(const DownloadOutcome.cancelled());
      }
    } on Object catch (error) {
      final failure = StreamFailure.classify(error);
      if (!job.completer.isCompleted) {
        job.completer.complete(
          DownloadOutcome(bytes: job.bytes, cached: false, failure: failure),
        );
      }
    } finally {
      job.activeResponse = null;
    }
  }

  bool _stopped(DownloadJob job) =>
      _disposed || job.cancelled || !generations.isCurrent(job.generation);

  Future<void> _waitWhilePaused(DownloadJob job) async {
    while (_paused && !_stopped(job)) {
      final completer = _resume ??= Completer<void>();
      await completer.future.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => null,
      );
    }
    if (_stopped(job)) throw const _Cancelled();
  }

  void _complete(DownloadJob job, DownloadOutcome outcome) {
    if (!job.completer.isCompleted) job.completer.complete(outcome);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    resumePrefetch();
    for (final job in _byKey.values.toList()) {
      _cancel(job);
    }
    _queue.clear();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
