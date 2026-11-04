import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';

class CollectionStorage extends NetworkStorageService {
  final actions = <String>[];
  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async => path == 'artist/'
      ? [NetworkEntry('album/', 'Album', directory: true)]
      : [
          NetworkEntry('subsonic/song/a.flac', 'A'),
          NetworkEntry('subsonic/song/a.flac', 'A duplicate'),
          NetworkEntry('subsonic/song/b.mp3', 'B'),
        ];
  @override
  Future<void> cacheAudio(
    String source, {
    bool background = false,
    bool manual = false,
  }) async {
    expect(manual, isTrue);
    actions.add('cache:$source');
  }

  @override
  Future<void> removeCachedAudio(String source) async =>
      actions.add('remove:$source');
}

void main() {
  const connection = NetworkConnection(
    id: 'test',
    name: 'Test',
    protocol: NetworkProtocol.subsonic,
    address: 'https://example.com',
  );
  test('artist traverses albums and processes each track once', () async {
    final storage = CollectionStorage();
    addTearDown(storage.dispose);
    expect(
      await storage.updateCollectionCache(connection, 'artist/', remove: false),
      2,
    );
    expect(storage.actions.length, 2);
    expect(storage.actions.every((a) => a.startsWith('cache:')), isTrue);
    storage.actions.clear();
    expect(
      await storage.updateCollectionCache(connection, 'artist/', remove: true),
      2,
    );
    expect(storage.actions.every((a) => a.startsWith('remove:')), isTrue);
  });
  test('cancel stops before the next track', () async {
    final storage = CollectionStorage();
    addTearDown(storage.dispose);
    var stop = false;
    expect(
      await storage.updateCollectionCache(
        connection,
        'album/',
        remove: false,
        cancelled: () => stop,
        onProgress: (_) => stop = true,
      ),
      1,
    );
    expect(storage.actions.length, 1);
  });
}
