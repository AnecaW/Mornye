import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/playback_state_machine.dart';

void main() {
  test('follows the buffering path of a slow start', () {
    final transitions = <String>[];
    final machine = PlaybackStateMachine(
      onTransition: (from, to, reason) =>
          transitions.add('${from.name}>${to.name}'),
    );
    expect(machine.transition(PlaybackPhase.resolvingTrack), isTrue);
    expect(machine.transition(PlaybackPhase.connecting), isTrue);
    expect(machine.transition(PlaybackPhase.buffering), isTrue);
    expect(machine.transition(PlaybackPhase.playing), isTrue);
    expect(transitions, [
      'idle>resolvingTrack',
      'resolvingTrack>connecting',
      'connecting>buffering',
      'buffering>playing',
    ]);
  });

  test('recovers from an underrun back to playing', () {
    final machine = PlaybackStateMachine()
      ..transition(PlaybackPhase.resolvingTrack)
      ..transition(PlaybackPhase.connecting)
      ..transition(PlaybackPhase.playing);
    expect(machine.transition(PlaybackPhase.buffering), isTrue);
    expect(machine.transition(PlaybackPhase.playing), isTrue);
  });

  test('supports seek, reconnection and recovery paths', () {
    final machine = PlaybackStateMachine()
      ..transition(PlaybackPhase.resolvingTrack)
      ..transition(PlaybackPhase.connecting)
      ..transition(PlaybackPhase.playing);
    expect(machine.transition(PlaybackPhase.seeking), isTrue);
    expect(machine.transition(PlaybackPhase.buffering), isTrue);
    expect(machine.transition(PlaybackPhase.reconnecting), isTrue);
    expect(machine.transition(PlaybackPhase.buffering), isTrue);
    expect(machine.transition(PlaybackPhase.recovering), isTrue);
    expect(machine.transition(PlaybackPhase.playing), isTrue);
  });

  test('rejects impossible transitions instead of applying them', () {
    final rejected = <String>[];
    final machine = PlaybackStateMachine(
      onRejected: (from, to, reason) => rejected.add('${from.name}>${to.name}'),
    );
    expect(machine.transition(PlaybackPhase.playing), isFalse);
    expect(machine.phase, PlaybackPhase.idle);
    expect(rejected, ['idle>playing']);
  });

  test('reset returns to idle from any phase', () {
    final machine = PlaybackStateMachine()
      ..transition(PlaybackPhase.resolvingTrack)
      ..transition(PlaybackPhase.playing);
    machine.reset(reason: 'track changed');
    expect(machine.phase, PlaybackPhase.idle);
    expect(machine.transition(PlaybackPhase.resolvingTrack), isTrue);
  });
}
