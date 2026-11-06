import 'dart:async';
import 'dart:math';

/// Sends a Navidrome/Subsonic scrobble. [submission] false announces the
/// "now playing" state; true records the play.
typedef ScrobbleSender =
    Future<void> Function(
      String source,
      String songId, {
      required bool submission,
      int? timeMs,
    });

/// Keeps Recently Played consistent between Mornye and the user's server.
///
/// A play only counts once it has actually started and reached the qualifying
/// position. Updates are sent immediately, retried with backoff when the server
/// is temporarily unreachable, and deduplicated per track session.
class RecentlyPlayedSync {
  RecentlyPlayedSync({
    required this.send,
    this.qualifyAfter = const Duration(seconds: 30),
    this.maxAttempts = 5,
    this.initialRetry = const Duration(seconds: 2),
    this.maxRetry = const Duration(seconds: 32),
    this.onLog,
    Random? random,
  }) : _random = random ?? Random();

  final ScrobbleSender send;
  final Duration qualifyAfter;
  final int maxAttempts;
  final Duration initialRetry;
  final Duration maxRetry;
  final void Function(String message)? onLog;
  final Random _random;

  final _pending = <_PendingScrobble>[];
  bool _flushing = false;
  Completer<void>? _flushDone;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  bool _disposed = false;

  String? _source;
  String? _songId;
  int _session = 0;
  bool _nowPlayingSent = false;
  bool _qualifiedSent = false;
  Duration _maxPosition = Duration.zero;

  int get pendingCount => _pending.length;
  bool get hasPending => _pending.isNotEmpty;

  /// Feeds actual playback state. Call only with a network source; local files
  /// are handled by the existing local history.
  void update({
    required String? source,
    required String? songId,
    required Duration position,
    Duration? duration,
    required bool playing,
    required bool ended,
  }) {
    if (_disposed || source == null || songId == null) return;
    if (source != _source || songId != _songId) {
      _source = source;
      _songId = songId;
      _session++;
      _nowPlayingSent = false;
      _qualifiedSent = false;
      _maxPosition = Duration.zero;
    }
    if (position > _maxPosition) _maxPosition = position;

    // A selected track that never produced audio is not history.
    if (!playing && _maxPosition == Duration.zero && !ended) return;

    if (playing) {
      if (!_nowPlayingSent) {
        _nowPlayingSent = true;
        _enqueue(source, songId, submission: false, session: _session);
      }
      if (!_qualifiedSent && _qualifies(_maxPosition, duration)) {
        _qualifiedSent = true;
        _enqueue(source, songId, submission: true, session: _session);
      }
    } else if (ended && !_qualifiedSent && _qualifies(_maxPosition, duration)) {
      _qualifiedSent = true;
      _enqueue(source, songId, submission: true, session: _session);
    }
  }

  /// True when [position] passes the play threshold: half the track or
  /// [qualifyAfter], whichever is shorter.
  bool _qualifies(Duration position, Duration? duration) {
    if (position <= Duration.zero) return false;
    if (duration != null && duration > Duration.zero) {
      final half = Duration(milliseconds: duration.inMilliseconds ~/ 2);
      final threshold = half < qualifyAfter ? half : qualifyAfter;
      return position >= threshold;
    }
    return position >= qualifyAfter;
  }

  void _enqueue(
    String source,
    String songId, {
    required bool submission,
    required int session,
  }) {
    if (_pending.any(
      (job) => job.session == session && job.submission == submission,
    )) {
      return;
    }
    _pending.add(
      _PendingScrobble(
        source: source,
        songId: songId,
        submission: submission,
        session: session,
      ),
    );
    onLog?.call(
      'queued ${submission ? 'submission' : 'now-playing'} '
      'session=$session',
    );
    unawaited(_flush());
  }

  /// Sends queued updates. When a send is already in progress, this waits for
  /// it instead of returning early, so callers can observe the result.
  Future<void> _flush() {
    if (_disposed) return Future.value();
    if (_flushing) return _flushDone?.future ?? Future.value();
    _flushing = true;
    final done = _flushDone = Completer<void>();
    return _runFlush().whenComplete(() {
      _flushing = false;
      if (identical(_flushDone, done)) _flushDone = null;
      if (!done.isCompleted) done.complete();
    });
  }

  Future<void> _runFlush() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    while (_pending.isNotEmpty) {
      final job = _pending.first;
      try {
        await send(
          job.source,
          job.songId,
          submission: job.submission,
          timeMs: job.submission ? DateTime.now().millisecondsSinceEpoch : null,
        );
        _pending.removeAt(0);
        _retryAttempt = 0;
        onLog?.call('synced ${job.submission ? 'submission' : 'now-playing'}');
      } on Object {
        job.attempts++;
        if (job.attempts >= maxAttempts) {
          _pending.removeAt(0);
          onLog?.call(
            'dropped ${job.submission ? 'submission' : 'now-playing'}',
          );
          continue;
        }
        _retryAttempt++;
        _scheduleRetry();
        return;
      }
    }
  }

  void _scheduleRetry() {
    if (_disposed) return;
    final base = initialRetry.inMilliseconds * (1 << min(_retryAttempt - 1, 5));
    final capped = min(base, maxRetry.inMilliseconds);
    final delay = (capped * (0.8 + _random.nextDouble() * 0.4)).round();
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: delay), () {
      unawaited(_flush());
    });
    onLog?.call('scrobble retry in ${delay}ms');
  }

  /// Retries now, e.g. after the app returns to the foreground.
  Future<void> retryNow() {
    _retryTimer?.cancel();
    _retryTimer = null;
    return _flush();
  }

  /// Waits for the current queue, including retries that are due now.
  Future<void> flush() => _flush();

  void reset() {
    _source = null;
    _songId = null;
    _session++;
    _nowPlayingSent = false;
    _qualifiedSent = false;
    _maxPosition = Duration.zero;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _pending.clear();
  }
}

class _PendingScrobble {
  _PendingScrobble({
    required this.source,
    required this.songId,
    required this.submission,
    required this.session,
  });

  final String source;
  final String songId;
  final bool submission;
  final int session;
  int attempts = 0;
}
