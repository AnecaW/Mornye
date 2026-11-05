import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/network_audio_cache.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playback_load.dart';
import 'support/subsonic_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late SubsonicFixture server;
  late NetworkStorageService storage;
  late Directory directory;
  late String source;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'audio_cache_wifi': false});
    server = await SubsonicFixture.start();
    server.audio = [102, 76, 97, 67, ...List.filled(10000, 0)];
    directory = await Directory.systemTemp.createTemp('playback-probe');
    String? saved;
    storage = NetworkStorageService(
      read: () async => saved,
      write: (v) async {
        saved = v;
      },
      ensureAccess: (_) async {},
      audioCache: NetworkAudioCache(directory: () async => directory),
    );
    await storage.save(server.connection());
    source = NetworkStorageService.source(
      'fixture',
      subsonicSongPath(server.song['id'] as String, 'flac'),
    );
  });
  tearDown(() async {
    await storage.dispose();
    await server.close();
    await directory.delete(recursive: true);
  });
  test(
    'preparation reads only a prefix and gives AVPlayer an extension-bearing progressive URL',
    () async {
      final url = await storage.preparePlayback(source, PlaybackLoad());
      expect(Uri.parse(url).path, endsWith('.flac'));
      expect(server.ranges, contains('bytes=0-4095'));
      expect(await storage.audioCache!.size(), 0);
      final count = server.requests.length;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Range', 'bytes=0-1');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.expand((x) => x).toList(), [102, 76]);
      expect(server.requests, hasLength(count));
      await storage.preparePlayback(source, PlaybackLoad());
      expect(server.requests, hasLength(count));
    },
  );
  test(
    'a server ignoring Range is checked without a full-file cache download',
    () async {
      server.ignoreRanges = true;
      final url = await storage.preparePlayback(source, PlaybackLoad());
      expect(url, contains('127.0.0.1'));
      expect(await storage.audioCache!.size(), 0);
    },
  );
  test(
    'HTML disguised as audio is rejected before the player is called',
    () async {
      server.audio = '<html>sign in</html>'.codeUnits;
      server.audioContentType = 'audio/flac';
      await expectLater(
        storage.preparePlayback(source, PlaybackLoad()),
        throwsA(
          isA<PlaybackFailure>().having(
            (e) => e.kind,
            'kind',
            PlaybackFailureKind.invalidAudio,
          ),
        ),
      );
    },
  );
  test(
    'Subsonic authentication errors are classified without leaking credentials',
    () async {
      server.mediaError = true;
      await expectLater(
        storage.preparePlayback(source, PlaybackLoad()),
        throwsA(
          isA<PlaybackFailure>().having(
            (e) => e.toString(),
            'safe message',
            isNot(contains('private')),
          ),
        ),
      );
    },
  );
  test('superseding a blocked request aborts preparation promptly', () async {
    server.blockMethod = 'stream';
    final load = PlaybackLoad();
    final work = storage.preparePlayback(source, load);
    final assertion = expectLater(work, throwsA(isA<PlaybackSuperseded>()));
    await server.held.future.timeout(const Duration(seconds: 2));
    load.cancel();
    await assertion.timeout(const Duration(seconds: 1));
    server.release.complete();
  });
  test(
    'verified complete cache plays offline and corrupt data is removed',
    () async {
      await storage.cacheAudio(source, manual: true);
      final local = await storage.preparePlayback(source, PlaybackLoad());
      expect(File(local).existsSync(), isTrue);
      server.disconnect = true;
      expect(await storage.preparePlayback(source, PlaybackLoad()), local);
      await File(local).writeAsBytes([0, 0, 0, 0]);
      expect(await storage.isAudioCached(source), isFalse);
      expect(File(local).existsSync(), isFalse);
    },
  );
}
