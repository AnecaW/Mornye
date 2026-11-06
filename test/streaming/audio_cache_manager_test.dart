import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/audio_cache_manager.dart';
import 'package:mornye/services/streaming/stream_types.dart';

StreamTrack _track({
  String account = 'account-a',
  String id = 'track-1',
  int? size = 10,
  String? cacheKey,
}) => StreamTrack(
  source: 'network://$account/subsonic/song/$id.flac',
  cacheKey: cacheKey ?? '$account/$id',
  accountId: account,
  trackId: id,
  format: 'flac',
  contentType: 'audio/flac',
  totalSize: size,
  label: id,
);

List<int> _bytes(int length, [int seed = 1]) =>
    List<int>.generate(length, (index) => (index + seed) % 251);

void main() {
  late Directory root;
  late AudioCacheManager cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mornye-audio-cache-');
    cache = AudioCacheManager(root: root);
  });

  tearDown(() async {
    await cache.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('partial writes are readable but never reported complete', () async {
    final track = _track();
    final entry = await cache.create(track);
    await entry.write(0, _bytes(6));
    await entry.flush();
    expect(entry.isComplete, isFalse);
    expect(entry.cachedBytes, 6);
    expect(entry.ranges.firstMissing(0, 10), 6);
    expect(await entry.read(0, 6), _bytes(6));
    expect(await entry.read(6, 10), isNull);
    expect(await entry.finish(), isFalse);
    expect(entry.isComplete, isFalse);
  });

  test('completes only when every byte is present and verified', () async {
    final track = _track();
    final entry = await cache.create(track);
    await entry.write(0, _bytes(5));
    await entry.write(5, _bytes(5, 6));
    expect(await entry.finish(), isTrue);
    expect(entry.isComplete, isTrue);
    expect(await entry.read(0, 10), _bytes(10));
  });

  test('reopening a completed entry verifies and reuses it', () async {
    final track = _track();
    final entry = await cache.create(track);
    await entry.write(0, _bytes(10));
    expect(await entry.finish(), isTrue);
    await entry.flush();
    await cache.dispose();

    cache = AudioCacheManager(root: root);
    final reopened = await cache.open(track);
    expect(reopened, isNotNull);
    expect(reopened!.isComplete, isTrue);
    expect(await reopened.read(0, 10), _bytes(10));
  });

  test('corrupted cache data is discarded, not trusted', () async {
    final track = _track();
    final entry = await cache.create(track);
    await entry.write(0, _bytes(10));
    expect(await entry.finish(), isTrue);
    final segment = entry.meta.segments.single;
    final file = File('${entry.directory.path}/${segment.file}');
    final corrupted = Uint8List.fromList(await file.readAsBytes());
    corrupted[0] = (corrupted[0] + 1) % 256;
    await file.writeAsBytes(corrupted);
    await cache.dispose();

    cache = AudioCacheManager(root: root);
    final reopened = await cache.open(track);
    expect(reopened, isNull);
    expect(await cache.stats(), isA<AudioCacheStats>());
  });

  test('an account never reads another account cache entry', () async {
    final first = await cache.create(_track());
    await first.write(0, _bytes(10));
    await first.finish();

    final other = _track(account: 'account-b');
    expect(await cache.open(other), isNull);
    final second = await cache.create(other);
    expect(second.isEmpty, isTrue);
  });

  test('a seek writes a second segment and overwrites the overlap', () async {
    final track = _track(size: 20);
    final entry = await cache.create(track);
    await entry.write(0, _bytes(10));
    await entry.write(8, _bytes(12, 40));
    expect(entry.ranges.spans.length, greaterThanOrEqualTo(1));
    final reread = await entry.read(8, 20);
    expect(reread, _bytes(12, 40));
    expect(await entry.read(0, 8), _bytes(8));
  });

  test('resumes an interrupted download from the cached prefix', () async {
    final track = _track();
    final first = await cache.create(track);
    await first.write(0, _bytes(4));
    await first.flush();
    await cache.dispose();

    cache = AudioCacheManager(root: root);
    final resumed = await cache.open(track);
    expect(resumed, isNotNull);
    final offset = resumed!.contiguousEndFrom(0);
    expect(offset, 4);
    await resumed.write(offset, _bytes(6, 5));
    expect(await resumed.finish(), isTrue);
    expect(await resumed.read(0, 10), _bytes(10));
  });

  test('evicts least-recently-used entries but keeps pinned ones', () async {
    final manager = AudioCacheManager(root: root, maxBytes: 20);
    final a = _track(id: 'a');
    final b = _track(id: 'b');
    final c = _track(id: 'c');
    for (final track in [a, b, c]) {
      final entry = await manager.create(track);
      await entry.write(0, _bytes(10));
      await entry.finish();
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final evicted = await manager.evict(pinnedKeys: {b.cacheKey});
    expect(evicted, greaterThan(0));
    expect(await manager.open(a), isNull);
    expect(await manager.open(b), isNotNull);
    final stats = await manager.stats();
    expect(stats.bytes, lessThanOrEqualTo(20));
    await manager.dispose();
  });

  test('clearing the cache keeps the active entry readable', () async {
    final active = _track(id: 'active');
    final other = _track(id: 'other');
    final activeEntry = await cache.create(active);
    await activeEntry.write(0, _bytes(10));
    await activeEntry.finish();
    final otherEntry = await cache.create(other);
    await otherEntry.write(0, _bytes(5));
    await otherEntry.flush();

    final removed = await cache.clear(keepKeys: {active.cacheKey});
    expect(removed, 1);
    expect(await cache.open(other), isNull);
    expect(await activeEntry.read(0, 10), _bytes(10));
    expect(activeEntry.isComplete, isTrue);
  });
}
