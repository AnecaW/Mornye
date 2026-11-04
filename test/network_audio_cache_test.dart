import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/network_audio_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late NetworkAudioCache cache;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'audio_cache_wifi': false});
    directory = await Directory.systemTemp.createTemp('audio-cache-');
    cache = NetworkAudioCache(directory: () async => directory);
    await cache.initialize();
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'one cache fill, incomplete files hidden, completed data survives restart',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      var downloads = 0;
      Future<void> download(File file, int limit) async {
        downloads++;
        await file.writeAsBytes([1, 2]);
        started.complete();
        await release.future;
        await file.writeAsBytes([1, 2, 3, 4]);
      }

      final first = cache.fetch('server/song', 'flac', download);
      await started.future;
      final second = cache.fetch('server/song', 'flac', download);
      expect(await cache.lookup('server/song', 'flac'), isNull);
      release.complete();
      await Future.wait([first, second]);
      expect(downloads, 1);
      final restarted = NetworkAudioCache(directory: () async => directory);
      expect(
        await (await restarted.lookup('server/song', 'flac'))!.readAsBytes(),
        [1, 2, 3, 4],
      );
      expect(await restarted.lookup('other-account/song', 'flac'), isNull);
    },
  );

  test(
    'restart removes abandoned partial files and keeps completed music',
    () async {
      await cache.fetch('complete', 'flac', (file, _) async {
        await file.writeAsBytes([1, 2]);
      });
      final abandoned = await File(
        '${directory.path}/abandoned.flac.part',
      ).writeAsBytes([3]);
      final restarted = NetworkAudioCache(directory: () async => directory);
      await restarted.initialize();
      expect(await abandoned.exists(), isFalse);
      expect(await restarted.lookup('complete', 'flac'), isNotNull);
    },
  );

  test(
    'explicit caching still works with automatic caching disabled',
    () async {
      cache.enabled = false;
      await cache.fetch('manual', 'mp3', (file, _) async {
        await file.writeAsBytes([1, 2]);
      }, manual: true);
      expect(await cache.lookup('manual', 'mp3'), isNotNull);
    },
  );

  test('failed fills are removed and can be retried', () async {
    await expectLater(
      cache.fetch('song', 'mp3', (file, _) async {
        await file.writeAsBytes([1]);
        throw const HttpException('Interrupted');
      }),
      throwsA(isA<HttpException>()),
    );
    expect(await cache.lookup('song', 'mp3'), isNull);
    expect(await cache.size(), 0);
    await cache.fetch('song', 'mp3', (file, _) async {
      await file.writeAsBytes([1, 2]);
    });
    expect(await cache.size(), 2);
  });

  test('LRU eviction and clearing never touch external downloads', () async {
    final permanent = await File(
      '${directory.parent.path}/permanent-${directory.uri.pathSegments.where((s) => s.isNotEmpty).last}.flac',
    ).writeAsBytes([9]);
    addTearDown(() => permanent.delete());
    cache.maxBytes = 4;
    await cache.fetch('old', 'flac', (file, _) async {
      await file.writeAsBytes([1, 2, 3]);
    });
    final old = (await cache.lookup('old', 'flac'))!;
    await old.setLastModified(DateTime(2000));
    await cache.fetch('new', 'flac', (file, _) async {
      await file.writeAsBytes([4, 5, 6]);
    });
    expect(await cache.lookup('old', 'flac'), isNull);
    expect(await cache.lookup('new', 'flac'), isNotNull);
    await cache.clear();
    expect(await cache.size(), 0);
    expect(await permanent.readAsBytes(), [9]);
  });
}
