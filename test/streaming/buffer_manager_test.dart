import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/buffer_manager.dart';
import 'package:mornye/services/streaming/playback_state_machine.dart';

void main() {
  test('adapts the target upward when the link barely outruns the file', () {
    final slow = BufferManager().targetFor(
      bitrateBytesPerSecond: 200000,
      throughputBytesPerSecond: 210000,
    );
    final comfortable = BufferManager().targetFor(
      bitrateBytesPerSecond: 200000,
      throughputBytesPerSecond: 2000000,
    );
    expect(slow.inSeconds, greaterThan(comfortable.inSeconds));
    expect(slow.inSeconds, greaterThanOrEqualTo(12));
  });

  test('stalls grow the target and a smooth stretch shrinks it', () {
    final buffers = BufferManager();
    final base = buffers.targetFor(
      bitrateBytesPerSecond: 200000,
      throughputBytesPerSecond: 2000000,
    );
    buffers.onStall();
    final afterStall = buffers.targetFor(
      bitrateBytesPerSecond: 200000,
      throughputBytesPerSecond: 2000000,
    );
    expect(afterStall, greaterThan(base));
    expect(buffers.stalls, 1);
  });

  test('reports urgency against the adaptive target', () {
    final buffers = BufferManager();
    final health = buffers.evaluate(
      bufferedAheadBytes: 5000,
      bitrateBytesPerSecond: 200000,
      throughputBytesPerSecond: 50000,
      phase: PlaybackPhase.playing,
    );
    expect(health.buffered, const Duration(milliseconds: 25));
    expect(health.urgency, BufferUrgency.critical);
    expect(health.shouldWaitForMore, isTrue);
    expect(health.target.inSeconds, greaterThanOrEqualTo(18));
  });

  test('keeps downloaded and decoded bytes separate', () {
    final buffers = BufferManager();
    buffers.onDownloaded(5000000);
    buffers.onDecoded(
      position: const Duration(seconds: 10),
      bitrateBytesPerSecond: 200000,
      sampleRate: 44100,
      channels: 2,
      bitsPerSample: 16,
    );
    expect(buffers.downloadedSourceBytes, 5000000);
    expect(buffers.decodedSourceBytes, 2000000);
    expect(buffers.decodedPcmBytes, 44100 * 2 * 2 * 10);
    expect(buffers.undecodedBytes, 3000000);
  });

  test('a healthy buffer needs no wait', () {
    final buffers = BufferManager();
    final health = buffers.evaluate(
      bufferedAheadBytes: 200000 * 20,
      bitrateBytesPerSecond: 200000,
      throughputBytesPerSecond: 2000000,
      phase: PlaybackPhase.playing,
    );
    expect(health.urgency, BufferUrgency.healthy);
    expect(health.shouldWaitForMore, isFalse);
  });
}
