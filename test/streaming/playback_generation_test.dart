import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/playback_generation.dart';

void main() {
  test('advance invalidates only older generations', () {
    final manager = GenerationManager(startAt: 100);
    final first = manager.current;
    expect(first.id, 100);
    expect(manager.isCurrent(first), isTrue);
    final second = manager.advance('skip');
    expect(second.id, 101);
    expect(manager.isCurrent(first), isFalse);
    expect(manager.isCurrent(second), isTrue);
  });

  test('rapid skips leave exactly the last generation valid', () async {
    final manager = GenerationManager();
    final created = <PlaybackGeneration>[];
    for (var index = 0; index < 10; index++) {
      created.add(manager.advance('skip $index'));
    }
    final valid = created.where(manager.isCurrent).toList();
    expect(valid, hasLength(1));
    expect(valid.single.id, created.last.id);
    await manager.dispose();
  });

  test('listeners see each generation synchronously', () async {
    final manager = GenerationManager();
    final seen = <int>[];
    final subscription = manager.changes.listen(
      (generation) => seen.add(generation.id),
    );
    manager.advance('one');
    expect(seen, [101]);
    manager.advance('two');
    expect(seen, [101, 102]);
    await subscription.cancel();
    await manager.dispose();
  });

  test(
    'waiting for invalidation completes when a newer track starts',
    () async {
      final manager = GenerationManager();
      final generation = manager.current;
      final waiting = manager.waitForInvalidation(
        generation,
        timeout: const Duration(seconds: 1),
      );
      manager.advance('new selection');
      expect(await waiting, isTrue);
      await manager.dispose();
    },
  );

  test('waiting times out for a still-current generation', () async {
    final manager = GenerationManager();
    final result = await manager.waitForInvalidation(
      manager.current,
      timeout: const Duration(milliseconds: 10),
    );
    expect(result, isFalse);
    await manager.dispose();
  });
}
