import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/subsonic_response_cache.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'support/subsonic_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('subsonic-response-');
  });
  tearDown(() => directory.delete(recursive: true));
  SubsonicResponseCache cache({
    Duration ttl = const Duration(minutes: 5),
    int maxEntries = 256,
  }) => SubsonicResponseCache(
    directory: () async => directory,
    ttl: ttl,
    maxEntries: maxEntries,
  );

  test('artists persist across clients and fresh scans bypass them', () async {
    final server = await SubsonicFixture.start();
    addTearDown(server.close);
    final storage = NetworkStorageService(
      metadataCache: cache(),
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {},
    );
    addTearDown(storage.dispose);
    final first = storage.openSubsonic(server.connection());
    await first.list('subsonic/artists/');
    first.close();
    final count = server.requests.length;
    final next = storage.openSubsonic(server.connection());
    await next.list('subsonic/artists/');
    next.close();
    expect(server.requests.length, count);
    final fresh = storage.openSubsonic(server.connection(), fresh: true);
    await fresh.list('subsonic/artists/');
    fresh.close();
    expect(server.requests.length, count + 1);
  });

  test(
    'restart retains metadata; account identity prevents credential mixups',
    () async {
      var reads = 0;
      Future<Map<String, dynamic>> fetch() async => {
        'status': 'ok',
        'value': ++reads,
      };
      await cache().request('user / private-password', 'getAlbum', {
        'id': 'a',
      }, fetch);
      expect(
        (await cache().request('user / private-password', 'getAlbum', {
          'id': 'a',
        }, fetch))['value'],
        1,
      );
      expect(
        (await cache().request('other-user', 'getAlbum', {
          'id': 'a',
        }, fetch))['value'],
        2,
      );
      expect(
        directory.listSync().every((f) => !f.path.contains('private-password')),
        isTrue,
      );
    },
  );

  test(
    'invalidation prevents an old in-flight response repopulating cache',
    () async {
      final service = cache();
      final started = Completer<void>(), release = Completer<void>();
      final old = service.request('user', 'getPlaylists', {}, () async {
        started.complete();
        await release.future;
        return {'status': 'ok', 'value': 'old'};
      });
      await started.future;
      await service.invalidate('user');
      release.complete();
      await old;
      expect(
        (await service.request(
          'user',
          'getPlaylists',
          {},
          () async => {'status': 'ok', 'value': 'new'},
        ))['value'],
        'new',
      );
    },
  );

  test(
    'stale metadata is usable offline, but authentication errors propagate',
    () async {
      final service = cache(ttl: Duration.zero);
      await service.request('user', 'getSong', {
        'id': 'x',
      }, () async => {'status': 'ok', 'value': 1});
      final offline = await service.request('user', 'getSong', {
        'id': 'x',
      }, () async => throw const SocketException('offline'));
      expect(offline['value'], 1);
      await expectLater(
        service.request('user', 'getSong', {
          'id': 'x',
        }, () async => throw const SubsonicException(40)),
        throwsA(isA<SubsonicException>()),
      );
    },
  );

  test(
    'cache limits remove old entries without touching unrelated files',
    () async {
      final service = cache(maxEntries: 1);
      final keep = await File('${directory.path}/keep.flac').writeAsBytes([1]);
      await service.request('user', 'getAlbum', {
        'id': 'a',
      }, () async => {'status': 'ok'});
      await service.request('user', 'getAlbum', {
        'id': 'b',
      }, () async => {'status': 'ok'});
      expect(
        directory.listSync().where((f) => f.path.endsWith('.json')),
        hasLength(1),
      );
      expect(await keep.exists(), isTrue);
    },
  );
}
