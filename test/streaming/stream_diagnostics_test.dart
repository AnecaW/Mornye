import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_diagnostics.dart';
import 'package:mornye/services/streaming/stream_types.dart';

void main() {
  test('computes time to first audio and connection latencies', () {
    var now = DateTime(2026, 1, 1, 12);
    final diagnostics = StreamDiagnostics(clock: () => now);
    final generation = GenerationManager().current;
    final timeline = diagnostics.begin(
      generation,
      label: 'network://server/track',
      cacheHit: false,
    );
    now = now.add(const Duration(milliseconds: 200));
    diagnostics.markConnected(timeline);
    now = now.add(const Duration(milliseconds: 300));
    diagnostics.markFirstByte(timeline);
    now = now.add(const Duration(milliseconds: 900));
    diagnostics.markFirstAudio(timeline);

    expect(timeline.connectionLatency, const Duration(milliseconds: 200));
    expect(timeline.firstByteLatency, const Duration(milliseconds: 500));
    expect(timeline.timeToFirstAudio, const Duration(milliseconds: 1400));
  });

  test('tracks cache hit rate and buffering aggregates', () {
    var now = DateTime(2026);
    final diagnostics = StreamDiagnostics(clock: () => now);
    final generations = GenerationManager();
    final hit = diagnostics.begin(
      generations.advance('hit'),
      label: 'a',
      cacheHit: true,
    );
    now = now.add(const Duration(seconds: 1));
    diagnostics.noteBufferingStart(hit.generation);
    now = now.add(const Duration(seconds: 2));
    diagnostics.noteBufferingEnd(hit.generation);
    diagnostics.begin(generations.advance('miss'), label: 'b', cacheHit: false);
    expect(diagnostics.cacheHitRate, closeTo(0.5, 0.001));
    expect(diagnostics.averageBufferingMilliseconds, 2000);
  });

  test('history is bounded and never contains URLs or credentials', () {
    final diagnostics = StreamDiagnostics(historyLimit: 2);
    final generations = GenerationManager();
    for (var index = 0; index < 4; index++) {
      final timeline = diagnostics.begin(
        generations.advance('track $index'),
        label: 'https://user:password@nas/rest/stream?apiKey=secret&id=$index',
        cacheHit: false,
      );
      diagnostics.noteFailure(
        timeline.generation,
        const StreamFailure(StreamFailureKind.network, retryable: true),
      );
    }
    expect(diagnostics.history, hasLength(2));
    final encoded = jsonEncode(diagnostics.snapshot());
    expect(encoded, isNot(contains('password')));
    expect(encoded, isNot(contains('apiKey')));
    expect(encoded, isNot(contains('https://')));
    expect(diagnostics.failedPlaybacks, 4);
  });

  test('safe labels are stable and do not expose the input', () {
    final label = StreamDiagnostics.safeLabel('secret-track-id');
    expect(label, hasLength(8));
    expect(label, isNot(contains('secret')));
    expect(StreamDiagnostics.safeLabel('secret-track-id'), label);
  });
}
