import 'package:flutter/services.dart';
import 'package:mornye/services/playback_buffer_policy.dart';
import 'package:mornye/utils/logger.dart';
import 'dart:async';
import 'dart:io';

enum PlaybackPreparationStage {
  idle,
  resolvingSource,
  connecting,
  validatingStream,
  buffering,
  readyToPlay,
  playing,
  recovering,
  failed,
}

/// One selected track owns its preparation, backoff and bounded prefetch.
class PlaybackLoad {
  PlaybackLoad({this.requestId, this.bitrate, this.prefetch = false});
  final bool prefetch;
  final int? bitrate;
  PlaybackBufferPolicy bufferPolicy = const PlaybackBufferPolicy();
  PlaybackPreparationStage stage = PlaybackPreparationStage.idle;
  final Stopwatch clock = Stopwatch()..start();
  int receivedBytes = 0, requests = 0;
  void mark(PlaybackPreparationStage next, {int? bytes, int? status}) {
    if (cancelled) return;
    stage = next;
    if (bytes != null) receivedBytes = bytes;
    AppLogger('PlaybackPreparation').d(
      'request=$requestId prefetch=$prefetch stage=${next.name} elapsedMs=${clock.elapsedMilliseconds} bytes=$receivedBytes requests=$requests${status == null ? '' : ' status=$status'}',
    );
  }

  final int? requestId;
  String? preparedPath;
  final _cancelled = Completer<void>();
  final _cleanup = <void Function()>[];
  bool get cancelled => _cancelled.isCompleted;
  void check() {
    if (cancelled) throw const PlaybackSuperseded();
  }

  void Function() onCancel(void Function() action) {
    if (cancelled) {
      action();
    } else {
      _cleanup.add(action);
    }
    return () => _cleanup.remove(action);
  }

  void cancel() {
    if (cancelled) return;
    _cancelled.complete();
    for (final action in _cleanup) {
      action();
    }
    _cleanup.clear();
  }

  Future<T> wait<T>(Future<T> work) => Future.any([
    work,
    _cancelled.future.then<T>((_) => throw const PlaybackSuperseded()),
  ]);
  Future<void> backoff(int attempt, {Duration? retryAfter}) {
    final base = Duration(milliseconds: 350 * (1 << attempt));
    final delay = retryAfter != null && retryAfter > base ? retryAfter : base;
    return wait(Future<void>.delayed(delay));
  }
}

class PlaybackSuperseded implements Exception {
  const PlaybackSuperseded();
}

enum PlaybackFailureKind {
  network,
  timeout,
  authentication,
  missing,
  invalidAudio,
  cache,
  player,
}

class PlaybackFailure implements Exception {
  const PlaybackFailure(this.kind, {this.status, this.retryAfter});
  final Duration? retryAfter;
  final PlaybackFailureKind kind;
  final int? status;
  bool get retryable =>
      kind == PlaybackFailureKind.network ||
      kind == PlaybackFailureKind.timeout ||
      kind == PlaybackFailureKind.player;
  @override
  String toString() => 'playback_${kind.name}';
  static PlaybackFailure classify(Object error) {
    if (error is PlaybackFailure) return error;
    if (error is StateError && error.message == 'Audio file is unavailable') {
      return const PlaybackFailure(PlaybackFailureKind.missing);
    }
    if (error is TimeoutException)
      return const PlaybackFailure(PlaybackFailureKind.timeout);
    if (error is PlatformException) {
      final detail = error.details?.toString() ?? '';
      final code = int.tryParse(
        RegExp(r'code=(-?\d+)').firstMatch(detail)?.group(1) ?? '',
      );
      if ((detail.contains('domain=NSURLErrorDomain') ||
              detail.contains('domain=MornyePlayback')) &&
          code == -1001) {
        return const PlaybackFailure(PlaybackFailureKind.timeout);
      }
      if (detail.contains('domain=NSURLErrorDomain') &&
          [-1003, -1004, -1005, -1006, -1009].contains(code)) {
        return const PlaybackFailure(PlaybackFailureKind.network);
      }
    }
    if (error is SocketException || error is HttpException) {
      return const PlaybackFailure(PlaybackFailureKind.network);
    }
    if (error is FileSystemException) {
      return const PlaybackFailure(PlaybackFailureKind.cache);
    }
    return const PlaybackFailure(PlaybackFailureKind.player);
  }
}
