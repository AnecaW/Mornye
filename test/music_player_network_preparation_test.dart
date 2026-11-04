import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/playback_preparation.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'support/music_player_automix_harness.dart';

const tracks = [
  PlayableMedia(
    id: 'remote-one',
    source: 'https://example.invalid/one.flac',
    title: 'One',
    artist: 'Artist',
  ),
  PlayableMedia(
    id: 'remote-two',
    source: 'https://example.invalid/two.mp3',
    title: 'Two',
    artist: 'Artist',
  ),
];
void main() {
  setUpMusicPlayerHarness();
  test(
    'delayed readiness preserves selection and loading until audible',
    () async {
      final gate = Completer<void>();
      native.sourceGates[tracks.first.source] = gate;
      final starting = handler.setQueueAndPlay(tracks);
      await waitUntil(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
      expect(handler.mediaItem.value?.id, 'remote-one');
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      expect(musicPlayerRuntime.phase.value, PlaybackPhase.loading);
      expect(native.resumedSources, isEmpty);
      gate.complete();
      await starting;
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      expect(native.resumedSources, [tracks.first.source]);
    },
  );
  test(
    'rapid selections supersede a held preparation without playing it',
    () async {
      final gate = Completer<void>();
      native.sourceGates[tracks.first.source] = gate;
      final first = handler.setQueueAndPlay(tracks);
      await waitUntil(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
      await handler.skipToNext();
      gate.complete();
      await first;
      expect(handler.mediaItem.value?.id, 'remote-two');
      expect(native.resumedSources, [tracks.last.source]);
      for (var n = 0; n < 30; n++) {
        await handler.setQueueAndPlay(tracks, initialIndex: n % 2);
        expect(handler.mediaItem.value?.id, tracks[n % 2].id);
        expect(handler.playbackState.value.errorMessage, isNull);
      }
    },
  );
  test('runtime I/O failure recovers the selected track and queue', () async {
    await handler.setQueueAndPlay(tracks);
    await native.error('music-player', details: 'MEDIA_ERROR_IO');
    await waitUntil(() => native.resumedSources.length == 2);
    expect(handler.mediaItem.value?.id, 'remote-one');
    expect(handler.queue.value, hasLength(2));
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
  });
  test(
    'a native method which never answers cannot leave loading indefinitely',
    () async {
      final previous = AudioPlayer.preparationTimeout;
      AudioPlayer.preparationTimeout = const Duration(milliseconds: 20);
      final gate = Completer<void>();
      native.sourceGates[tracks.first.source] = gate;
      try {
        await handler.setQueueAndPlay(tracks);
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.error,
        );
        expect(handler.mediaItem.value?.id, 'remote-one');
        expect(native.resumedSources, isEmpty);
      } finally {
        AudioPlayer.preparationTimeout = previous;
        if (!gate.isCompleted) gate.complete();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
