/// The explicit phases audio streaming moves through. UI state is derived from
/// this rather than from individual network or decoder events.
enum PlaybackPhase {
  idle,
  resolvingTrack,
  connecting,
  buffering,
  playing,
  paused,
  seeking,
  reconnecting,
  recovering,
  error,
}

/// A guarded transition table for [PlaybackPhase].
///
/// Illegal transitions are rejected instead of silently applied; the engine
/// reports them so a race becomes visible rather than corrupting playback.
class PlaybackStateMachine {
  PlaybackStateMachine({
    void Function(PlaybackPhase from, PlaybackPhase to, String reason)?
    onTransition,
    void Function(PlaybackPhase from, PlaybackPhase to, String reason)?
    onRejected,
  }) : _onTransition = onTransition,
       _onRejected = onRejected;

  static const Map<PlaybackPhase, Set<PlaybackPhase>> allowed = {
    PlaybackPhase.idle: {PlaybackPhase.resolvingTrack, PlaybackPhase.error},
    PlaybackPhase.resolvingTrack: {
      PlaybackPhase.connecting,
      PlaybackPhase.buffering,
      PlaybackPhase.paused,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.connecting: {
      PlaybackPhase.buffering,
      PlaybackPhase.playing,
      PlaybackPhase.reconnecting,
      PlaybackPhase.recovering,
      PlaybackPhase.paused,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.buffering: {
      PlaybackPhase.playing,
      PlaybackPhase.paused,
      PlaybackPhase.seeking,
      PlaybackPhase.reconnecting,
      PlaybackPhase.recovering,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.playing: {
      PlaybackPhase.buffering,
      PlaybackPhase.paused,
      PlaybackPhase.seeking,
      PlaybackPhase.reconnecting,
      PlaybackPhase.recovering,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.paused: {
      PlaybackPhase.playing,
      PlaybackPhase.buffering,
      PlaybackPhase.seeking,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.seeking: {
      PlaybackPhase.buffering,
      PlaybackPhase.playing,
      PlaybackPhase.paused,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.reconnecting: {
      PlaybackPhase.buffering,
      PlaybackPhase.playing,
      PlaybackPhase.paused,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.recovering: {
      PlaybackPhase.buffering,
      PlaybackPhase.playing,
      PlaybackPhase.paused,
      PlaybackPhase.seeking,
      PlaybackPhase.idle,
      PlaybackPhase.error,
    },
    PlaybackPhase.error: {
      PlaybackPhase.idle,
      PlaybackPhase.resolvingTrack,
      PlaybackPhase.connecting,
      PlaybackPhase.buffering,
    },
  };

  final void Function(PlaybackPhase from, PlaybackPhase to, String reason)?
  _onTransition;
  final void Function(PlaybackPhase from, PlaybackPhase to, String reason)?
  _onRejected;

  PlaybackPhase _phase = PlaybackPhase.idle;
  PlaybackPhase get phase => _phase;

  bool get isPlaying => _phase == PlaybackPhase.playing;
  bool get isIdle => _phase == PlaybackPhase.idle;

  bool canTransitionTo(PlaybackPhase next) =>
      next == _phase || (allowed[_phase]?.contains(next) ?? false);

  /// Moves to [next] when the table permits it. Returns whether it applied.
  bool transition(PlaybackPhase next, {String reason = ''}) {
    if (next == _phase) return false;
    if (!canTransitionTo(next)) {
      _onRejected?.call(_phase, next, reason);
      return false;
    }
    final previous = _phase;
    _phase = next;
    _onTransition?.call(previous, next, reason);
    return true;
  }

  /// Returns to [PlaybackPhase.idle] from any phase, for a new selection or a
  /// stop. Idle-to-idle is a no-op.
  void reset({String reason = ''}) {
    if (_phase != PlaybackPhase.idle) {
      final previous = _phase;
      _phase = PlaybackPhase.idle;
      _onTransition?.call(previous, PlaybackPhase.idle, reason);
    }
  }
}
