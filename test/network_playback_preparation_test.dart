import 'package:mornye/services/subsonic_response_cache.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
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
      metadataCache: SubsonicResponseCache(
        directory: () async => Directory('${directory.path}/metadata'),
      ),
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
    'partial cache resumes at the exact offset when the origin ignores Range',
    () async {
      server.ignoreRanges = true;
      server.audio = [
        102,
        76,
        97,
        67,
        ...List.generate(600000, (i) => i % 251),
      ];
      final cache = storage.audioCache!;
      final path = subsonicSongPath(server.song['id'] as String, 'flac');
      final key =
          '${jsonEncode((await storage.connection('fixture')).toJson())}/$path';
      final started = Completer<void>(), release = Completer<void>();
      final fill = cache.fetch(key, 'flac', (file, _) async {
        await file.writeAsBytes(server.audio!.take(4).toList());
        cache.reportLength(key, server.audio!.length);
        started.complete();
        await release.future;
        await file.writeAsBytes(server.audio!);
      });
      await started.future;
      final client = HttpClient();
      try {
        final url = await storage.resolve(source, forPlayback: true);
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('Range', 'bytes=524288-524415');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          await response
              .expand((chunk) => chunk)
              .toList()
              .timeout(const Duration(seconds: 2)),
          server.audio!.sublist(524288, 524416),
        );
        expect(release.isCompleted, isFalse);
      } finally {
        client.close(force: true);
        release.complete();
        await fill;
      }
    },
  );
  for (final knownLength in [false, true]) {
    test(
      'cold playback does not wait for a stalled cache (length=$knownLength)',
      () async {
        final cache = storage.audioCache!;
        final path = subsonicSongPath(server.song['id'] as String, 'flac');
        final key =
            '${jsonEncode((await storage.connection('fixture')).toJson())}/$path';
        final started = Completer<void>(), release = Completer<void>();
        final fill = cache.fetch(key, 'flac', (file, _) async {
          await file.writeAsBytes(server.audio!.take(4).toList());
          if (knownLength) cache.reportLength(key, server.audio!.length);
          started.complete();
          await release.future;
          await file.writeAsBytes(server.audio!);
          cache.reportLength(key, server.audio!.length);
        });
        await started.future;
        final client = HttpClient();
        try {
          expect(await cache.lookup(key, 'flac'), isNull);
          final url = await storage.resolve(source, forPlayback: true);
          final playback = () async {
            final response = await (await client.getUrl(
              Uri.parse(url),
            )).close();
            expect(response.statusCode, 200);
            return response.expand((chunk) => chunk).toList();
          }();
          playback.ignore();
          expect(
            await playback.timeout(const Duration(seconds: 2)),
            server.audio,
          );
          expect(release.isCompleted, isFalse);
        } finally {
          client.close(force: true);
          release.complete();
          await fill;
        }
        expect(
          await (await cache.lookup(key, 'flac'))!.readAsBytes(),
          server.audio,
        );
      },
    );
  }
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
  test(
    'rejected HTTP responses release pool slots before later recovery',
    () async {
      server.mediaStatus = 503;
      for (var i = 0; i < 8; i++) {
        await expectLater(
          storage
              .preparePlayback(source, PlaybackLoad())
              .timeout(const Duration(seconds: 2)),
          throwsA(
            isA<PlaybackFailure>().having((e) => e.status, 'status', 503),
          ),
        );
      }
      server.mediaStatus = null;
      expect(
        await storage
            .preparePlayback(source, PlaybackLoad())
            .timeout(const Duration(seconds: 2)),
        contains('127.0.0.1'),
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
    'shared preparation keeps the remaining subscriber when one cancels',
    () async {
      server.blockMethod = 'stream';
      final first = PlaybackLoad(), second = PlaybackLoad();
      final a = storage.preparePlayback(source, first);
      final cancelled = expectLater(a, throwsA(isA<PlaybackSuperseded>()));
      await server.held.future.timeout(const Duration(seconds: 2));
      final b = storage.preparePlayback(source, second);
      final end = DateTime.now().add(const Duration(seconds: 2));
      while (second.stage == PlaybackPreparationStage.idle ||
          second.stage == PlaybackPreparationStage.resolvingSource) {
        if (DateTime.now().isAfter(end)) fail('Second subscriber did not join');
        await Future<void>.delayed(Duration.zero);
      }
      first.cancel();
      await cancelled;
      server.release.complete();
      expect(
        await b.timeout(const Duration(seconds: 2)),
        contains('127.0.0.1'),
      );
      expect(
        server.requests.where((r) => r.path.endsWith('/stream.view')),
        hasLength(1),
      );
      expect(second.receivedBytes, greaterThan(0));
    },
  );
  test(
    'native underflow changes the next preparation policy for the same account',
    () async {
      final first = PlaybackLoad();
      await storage.preparePlayback(source, first);
      await storage.recordPlaybackStall(source);
      final next = PlaybackLoad();
      await storage.preparePlayback(source, next);
      expect(
        next.bufferPolicy.minimumSeconds,
        greaterThan(first.bufferPolicy.minimumSeconds),
      );
      expect(next.bufferPolicy.minimumSeconds, lessThanOrEqualTo(3));
    },
  );
  test('consecutive audio preparations reuse the same server socket', () async {
    await storage.preparePlayback(source, PlaybackLoad());
    final second = NetworkStorageService.source(
      'fixture',
      subsonicSongPath('second', 'flac'),
    );
    await storage.preparePlayback(second, PlaybackLoad());
    final ports = [
      for (var i = 0; i < server.requests.length; i++)
        if (server.requests[i].path.contains('/stream.')) server.peerPorts[i],
    ];
    expect(ports, hasLength(2));
    expect(ports.toSet(), hasLength(1));
  });
  test(
    'closing an API client does not interrupt another pooled request',
    () async {
      server.blockMethod = 'getArtists';
      final blocked = storage.openSubsonic(server.connection(), fresh: true);
      final other = storage.openSubsonic(server.connection());
      addTearDown(other.close);
      final pending = blocked.request('getArtists');
      final failure = expectLater(pending, throwsA(anything));
      await server.held.future;
      blocked.close();
      await failure.timeout(const Duration(seconds: 1));
      final result = await other.request('ping');
      expect(result['status'], 'ok');
      final url = await storage.preparePlayback(source, PlaybackLoad());
      expect(url, contains('127.0.0.1'));
      server.release.complete();
    },
  );
  test(
    'closing the first metadata caller preserves a shared cache fetch',
    () async {
      server.blockMethod = 'getArtists';
      final first = storage.openSubsonic(server.connection());
      final second = storage.openSubsonic(server.connection());
      addTearDown(second.close);
      final a = first.request('getArtists');
      final cancelled = expectLater(a, throwsStateError);
      await server.held.future.timeout(const Duration(seconds: 2));
      final b = second.request('getArtists');
      first.close();
      await cancelled.timeout(const Duration(seconds: 1));
      server.release.complete();
      expect((await b.timeout(const Duration(seconds: 2)))['status'], 'ok');
      await cancelled;
      expect(
        server.requests.where((r) => r.path.endsWith('/getArtists.view')),
        hasLength(1),
      );
    },
  );
  test(
    'API calls keep their shared connection after each client is closed',
    () async {
      final first = storage.openSubsonic(server.connection());
      await first.request('ping');
      first.close();
      final second = storage.openSubsonic(server.connection());
      await second.request('ping');
      second.close();
      expect(server.peerPorts.toSet(), hasLength(1));
    },
  );
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
