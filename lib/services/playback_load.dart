import 'dart:async';
import 'dart:io';

/// One selected track owns its preparation, backoff and bounded prefetch.
class PlaybackLoad {
  PlaybackLoad({this.requestId});
  final int? requestId;
  String? preparedPath;
  final _cancelled = Completer<void>();
  final _cleanup = <void Function()>[];
  bool get cancelled => _cancelled.isCompleted;
  void check() {
    if (cancelled) throw const PlaybackSuperseded();
  }

  void onCancel(void Function() action) {
    if (cancelled) {
      action();
    } else {
      _cleanup.add(action);
    }
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
  Future<void> backoff(int attempt) =>
      wait(Future<void>.delayed(Duration(milliseconds: 350 * (1 << attempt))));
}

class PlaybackSuperseded implements Exception {
  const PlaybackSuperseded();
}

enum PlaybackFailureKind {
  network,
  authentication,
  missing,
  invalidAudio,
  cache,
  player,
}

class PlaybackFailure implements Exception {
  const PlaybackFailure(this.kind, {this.status});
  final PlaybackFailureKind kind;
  final int? status;
  bool get retryable =>
      kind == PlaybackFailureKind.network || kind == PlaybackFailureKind.player;
  @override
  String toString() => 'playback_${kind.name}';
  static PlaybackFailure classify(Object error) {
    if (error is PlaybackFailure) return error;
    if (error is StateError && error.message == 'Audio file is unavailable') {
      return const PlaybackFailure(PlaybackFailureKind.missing);
    }
    if (error is SocketException ||
        error is TimeoutException ||
        error is HttpException) {
      return const PlaybackFailure(PlaybackFailureKind.network);
    }
    if (error is FileSystemException) {
      return const PlaybackFailure(PlaybackFailureKind.cache);
    }
    return const PlaybackFailure(PlaybackFailureKind.player);
  }
}
