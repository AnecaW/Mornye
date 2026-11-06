import 'dart:async';

/// One user selection. Every network request, cache write and decoder task is
/// tagged with the generation that created it, so a late completion can never
/// touch a newer track.
class PlaybackGeneration {
  PlaybackGeneration._(this.id, this.reason);

  final int id;
  final String reason;

  @override
  String toString() => 'generation $id ($reason)';
}

/// Hands out monotonically increasing [PlaybackGeneration]s and notifies
/// listeners synchronously, so obsolete work is cancelled before the next
/// request starts.
class GenerationManager {
  GenerationManager({int startAt = 100}) : _next = startAt {
    _current = PlaybackGeneration._(startAt, 'initial');
  }

  int _next;
  late PlaybackGeneration _current;
  final _changes = StreamController<PlaybackGeneration>.broadcast(sync: true);
  bool _disposed = false;

  PlaybackGeneration get current => _current;
  int get currentId => _current.id;
  Stream<PlaybackGeneration> get changes => _changes.stream;

  /// Invalidates everything currently in flight. Returns the new generation.
  PlaybackGeneration advance(String reason) {
    if (_disposed) {
      throw StateError('The generation manager was disposed');
    }
    _next++;
    final next = PlaybackGeneration._(_next, reason);
    _current = next;
    _changes.add(next);
    return next;
  }

  /// Whether work created by [generation] may still write to shared state.
  bool isCurrent(PlaybackGeneration generation) =>
      !_disposed && generation.id == _current.id;

  bool isCurrentId(int id) => !_disposed && id == _current.id;

  /// Waits until [generation] is no longer current, or [timeout] elapses.
  /// Returns true when the generation was invalidated.
  Future<bool> waitForInvalidation(
    PlaybackGeneration generation, {
    Duration? timeout,
  }) {
    if (!isCurrent(generation)) return Future.value(true);
    final completer = Completer<bool>();
    late final StreamSubscription<PlaybackGeneration> subscription;
    Timer? timer;
    subscription = changes.listen((_) {
      if (!completer.isCompleted && !isCurrent(generation)) {
        completer.complete(true);
      }
    });
    if (timeout != null) {
      timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(false);
      });
    }
    return completer.future.whenComplete(() {
      timer?.cancel();
      unawaited(subscription.cancel());
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }
}
