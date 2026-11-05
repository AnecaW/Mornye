import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/library_source_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/server_scrobbling.dart';
import 'package:mornye/services/navidrome_library.dart';
import 'package:mornye/services/network_storage_service.dart';

class _DeviceCollections implements LibraryCollectionsDatabase {
  int writes = 0;
  @override
  Future<bool> migrateFromSharedPreferences() async => false;
  @override
  Future<LibraryCollectionsSnapshot> loadSnapshot() async =>
      const LibraryCollectionsSnapshot(
        wishlistRows: [],
        lovedRows: [],
        playlistRows: [],
        playlistTrackRows: [],
        favoriteArtistRows: [],
      );
  @override
  dynamic noSuchMethod(Invocation invocation) {
    writes++;
    throw StateError(
      'Server data must never be written into the local collections DB',
    );
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late HttpServer server;
  late NetworkStorageService storage;
  late NavidromeLibrary library;
  late Map<String, dynamic> playlist;
  late List<({String method, Map<String, List<String>> args, String verb})>
  calls;
  var starred = false;
  var rating = 0;
  var changed = 0;
  var authFailure = false;
  setUp(() async {
    calls = [];
    starred = false;
    rating = 0;
    changed = 0;
    authFailure = false;
    playlist = {
      'id': 'playlist / 日本',
      'name': 'Original',
      'changed': '0',
      'entry': [
        {'id': 'a', 'title': 'A', 'suffix': 'flac'},
        {'id': 'a', 'title': 'A', 'suffix': 'flac'},
        {'id': 'b', 'title': 'B', 'suffix': 'mp3'},
      ],
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final method = request.uri.pathSegments.last.replaceFirst('.view', '');
      final args = request.method == 'POST'
          ? Uri(
              query: await utf8.decoder.bind(request).join(),
            ).queryParametersAll
          : request.uri.queryParametersAll;
      calls.add((method: method, args: args, verb: request.method));
      final salt = args['s']?.single ?? '';
      final valid =
          args['t']?.single ==
              md5.convert(utf8.encode('secret$salt')).toString() &&
          salt.isNotEmpty;
      Map<String, dynamic> result = {'status': 'ok'};
      if (!valid || authFailure) {
        result = {
          'status': 'failed',
          'error': {'code': 40},
        };
      } else {
        switch (method) {
          case 'getAlbumList2':
            result['albumList2'] = {
              'album': [
                {'id': 'recent-album', 'played': '2026-11-05T10:00:00Z'},
              ],
            };
          case 'getAlbum':
            result['album'] = {
              'id': 'recent-album',
              'song': [
                {'id': 'unplayed', 'title': 'Never played', 'suffix': 'flac'},
                {
                  'id': 'played',
                  'title': 'Actually played',
                  'suffix': 'flac',
                  'played': '2026-11-05T10:00:00Z',
                },
                {
                  'id': 'played',
                  'title': 'Actually played',
                  'suffix': 'flac',
                  'played': '2026-11-05T11:00:00Z',
                },
              ],
            };
          case 'getPlaylist':
            result['playlist'] = playlist;
          case 'getPlaylists':
            result['playlists'] = {
              'playlist': [playlist],
            };
          case 'createPlaylist':
            if (args.containsKey('playlistId')) {
              playlist = {
                ...playlist,
                'changed': '${++changed}',
                'entry': [
                  for (final id in args['songId'] ?? <String>[])
                    {'id': id, 'title': id, 'suffix': 'flac'},
                ],
              };
            } else {
              playlist = {
                ...playlist,
                'name': args['name']!.single,
                'changed': '${++changed}',
              };
            }
            result['playlist'] = playlist;
          case 'updatePlaylist':
            playlist = {
              ...playlist,
              'name': args['name']!.single,
              'changed': '${++changed}',
            };
          case 'getSong':
            result['song'] = {
              'id': 'a',
              'title': 'A',
              'suffix': 'flac',
              'userRating': rating,
              if (starred) 'starred': '2026-01-01T00:00:00Z',
            };
          case 'star':
            starred = true;
          case 'unstar':
            starred = false;
          case 'setRating':
            rating = int.parse(args['rating']!.single);
          case 'getStarred2':
            result['starred2'] = {
              'song': [
                if (starred) {'id': 'a', 'title': 'A', 'suffix': 'flac'},
              ],
            };
          case 'getInternetRadioStations':
            result['internetRadioStations'] = {
              'internetRadioStation': [
                {
                  'id': 'radio',
                  'name': 'Server station',
                  'streamUrl': 'https://example.org/live',
                },
              ],
            };
        }
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'subsonic-response': result}));
      await request.response.close();
    });
    storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
      ensureAccess: (_) async {},
    );
    library = NavidromeLibrary(
      NetworkConnection(
        id: 'account-one',
        name: 'Server one',
        protocol: NetworkProtocol.subsonic,
        address: 'http://127.0.0.1:${server.port}/music/',
        username: 'user',
        password: 'secret',
      ),
      storage: storage,
    );
  });
  tearDown(() async {
    await storage.dispose();
    await server.close(force: true);
  });
  test(
    'ordered replacement preserves repeated ids and uses authenticated POST',
    () async {
      final base = await library.playlist('playlist / 日本', fresh: true);
      await library.editPlaylist(base, songs: ['b', 'a', 'a']);
      expect((await library.playlist(base.id, fresh: true)).songIds, [
        'b',
        'a',
        'a',
      ]);
      final mutation = calls.singleWhere((e) => e.method == 'createPlaylist');
      expect(mutation.verb, 'POST');
      expect(mutation.args['songId'], ['b', 'a', 'a']);
      expect(mutation.args['playlistId'], [base.id]);
      expect(
        calls.map((e) => e.args['s']!.single).toSet().length,
        calls.length,
      );
    },
  );
  test('removing final track sends an empty ordered membership', () async {
    final base = await library.playlist('p', fresh: true);
    await library.editPlaylist(base, songs: []);
    expect((await library.playlist('p', fresh: true)).songIds, isEmpty);
  });
  test(
    'external modification is rejected before overwriting server state',
    () async {
      final base = await library.playlist('p', fresh: true);
      playlist = {...playlist, 'changed': 'external', 'name': 'Another player'};
      await expectLater(
        library.editPlaylist(base, songs: ['b']),
        throwsA(isA<ServerConflict>()),
      );
      expect(calls.where((c) => c.method == 'createPlaylist'), isEmpty);
      expect(playlist['name'], 'Another player');
    },
  );
  test(
    'queued edits compare against preceding completed server write',
    () async {
      final base = await library.playlist('p', fresh: true);
      final first = library.editPlaylist(base, name: 'First');
      final second = library.editPlaylist(base, name: 'Second');
      final check = expectLater(second, throwsA(isA<ServerConflict>()));
      await first;
      await check;
      expect(playlist['name'], 'First');
    },
  );
  test('smart/read-only playlists cannot be mutated', () async {
    await expectLater(
      library.editPlaylist(
        ServerPlaylist({...playlist, 'readonly': true}),
        songs: ['x'],
      ),
      throwsStateError,
    );
    expect(calls, isEmpty);
  });
  test('create rename delete write to server', () async {
    await library.createPlaylist('New');
    expect((await library.playlists(fresh: true)).single['name'], 'New');
    final base = await library.playlist('p', fresh: true);
    await library.editPlaylist(base, name: 'Renamed');
    expect(playlist['name'], 'Renamed');
    await library.editPlaylist(
      await library.playlist('p', fresh: true),
      delete: true,
    );
    expect(calls.last.method, 'deletePlaylist');
  });
  test('stars and ratings are actual server state', () async {
    expect(await library.toggleSong('a'), isTrue);
    expect(starred, isTrue);
    expect(
      subsonicRows((await library.starred(fresh: true))['song']),
      hasLength(1),
    );
    expect(await library.toggleSong('a'), isFalse);
    await library.rate('a', 5);
    expect(rating, 5);
    await expectLater(library.rate('a', 6), throwsRangeError);
    await library.star('album', 'album', true);
    expect(calls.last.args['albumId'], ['album']);
    await library.star('artist', 'artist', false);
    expect(calls.last.args['artistId'], ['artist']);
  });
  test('authentication errors are surfaced without mutation replay', () async {
    authFailure = true;
    await expectLater(
      library.createPlaylist('Denied'),
      throwsA(isA<SubsonicException>()),
    );
    expect(calls, hasLength(1));
    expect(playlist['name'], 'Original');
  });
  test('scrobble preserves timestamp and submission intent', () async {
    final date = DateTime.utc(2026, 11, 5);
    await library.scrobble('a', submission: true, time: date);
    expect(calls.last.args['time'], ['${date.millisecondsSinceEpoch}']);
    expect(calls.last.args['submission'], ['true']);
  });
  test(
    'radio stations are retrieved and mutations use server endpoints',
    () async {
      expect(
        (await library.radios(fresh: true)).single['name'],
        'Server station',
      );
      await library.saveRadio('Music', 'https://example.org/live');
      expect(calls.last.method, 'createInternetRadioStation');
      await library.deleteRadio('radio');
      expect(calls.last.method, 'deleteInternetRadioStation');
      await expectLater(
        library.saveRadio('Bad', 'file:///secret'),
        throwsFormatException,
      );
    },
  );
  test(
    'failed playback submission persists and retries with original timestamp',
    () async {
      SharedPreferences.setMockInitialValues({});
      await storage.save(library.connection);
      final outbox = ServerScrobbleOutbox(storage: storage);
      final source = library.playable({
        'id': 'a',
        'title': 'A',
        'suffix': 'flac',
      }).source;
      final time = DateTime.utc(2026, 11, 5);
      authFailure = true;
      await outbox.enqueue(source, time);
      expect(await outbox.pendingCount(), 1);
      authFailure = false;
      await outbox.flush();
      expect(await outbox.pendingCount(), 0);
      expect(calls.last.method, 'scrobble');
      expect(calls.last.args['time'], ['${time.millisecondsSinceEpoch}']);
    },
  );
  test(
    'same song id on two servers keeps playback/cache identity distinct',
    () {
      final other = NavidromeLibrary(
        NetworkConnection(
          id: 'account-two',
          name: 'Two',
          protocol: NetworkProtocol.subsonic,
          address: 'http://localhost',
          username: 'u',
          password: 'p',
        ),
      );
      final song = {'id': 'same', 'title': 'Song', 'suffix': 'flac'};
      expect(library.playable(song).source, isNot(other.playable(song).source));
    },
  );

  test(
    'recent history uses real song timestamps, deduplicates by ID and bypasses cached reads',
    () async {
      final recent = await library.recentPlayed();
      expect(recent.songs, hasLength(1));
      expect(recent.songs.single['id'], 'played');
      expect(
        subsonicPlayedAt(recent.songs.single['played']),
        DateTime.utc(2026, 11, 5, 11),
      );
      expect(calls.where((c) => c.method == 'scrobble'), isEmpty);
      expect(subsonicPlayedAt(null), isNull);
      expect(subsonicPlayedAt('invalid'), isNull);
      expect(subsonicPlayedAt(0), isNull);
    },
  );

  test(
    'original collections actions create, load, add, remove and rename actual server playlists without local clones',
    () async {
      SharedPreferences.setMockInitialValues({});
      await storage.save(library.connection);
      final db = _DeviceCollections();
      final container = ProviderContainer(
        overrides: [
          librarySourceStorageProvider.overrideWithValue(storage),
          libraryCollectionsProvider.overrideWith(
            () => LibraryCollectionsNotifier(database: db),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await _until(
        () => container.read(libraryCollectionsProvider).playlists.isNotEmpty,
      );
      final id = serverPlaylistKey(
        library.connection.id,
        playlist['id'] as String,
      );
      await notifier.ensurePlaylistLoaded(id);
      expect(
        container.read(libraryCollectionsProvider).playlistById(id)!.tracks,
        hasLength(3),
      );
      final added = await notifier.addTracksToPlaylist(id, [
        library.track({'id': 'c', 'title': 'C', 'suffix': 'flac'}),
      ]);
      expect(added.addedCount, 1);
      expect(
        (await library.playlist(playlist['id'] as String, fresh: true)).songIds,
        ['a', 'a', 'b', 'c'],
      );
      final beforeRemove = container
          .read(libraryCollectionsProvider)
          .playlistById(id)!;
      await notifier.removeTracksFromPlaylist(id, [beforeRemove.tracks[1].key]);
      expect(
        (await library.playlist(playlist['id'] as String, fresh: true)).songIds,
        ['a', 'b', 'c'],
      );
      await notifier.renamePlaylist(id, 'From original UI');
      expect(playlist['name'], 'From original UI');
      await container
          .read(selectedLibrarySourceProvider.notifier)
          .select(serverMusicSource(library.connection.id));
      expect(await notifier.createPlaylist('Created on server'), id);
      expect(playlist['name'], 'Created on server');
      expect(
        container.read(scopedLibraryCollectionsProvider).playlists,
        hasLength(1),
      );
      await container
          .read(selectedLibrarySourceProvider.notifier)
          .select(deviceMusicSource);
      expect(
        container.read(scopedLibraryCollectionsProvider).playlists,
        isEmpty,
      );
      await container
          .read(selectedLibrarySourceProvider.notifier)
          .select(allMusicSources);
      expect(
        container.read(scopedLibraryCollectionsProvider).playlists,
        hasLength(1),
      );
      final export = jsonDecode(await notifier.exportCollectionsJson()) as Map;
      expect(export['playlists'], isEmpty);
      expect(db.writes, 0);
    },
  );
  test(
    'source choices track real saved connections and removal never selects device music',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [librarySourceStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      expect(
        await container.read(librarySourceConnectionsProvider.future),
        isEmpty,
      );
      await storage.save(library.connection);
      await _until(
        () =>
            container.read(librarySourceConnectionsProvider).value?.length == 1,
      );
      await container
          .read(selectedLibrarySourceProvider.notifier)
          .select(serverMusicSource(library.connection.id));
      await storage.remove(library.connection.id);
      await _until(
        () =>
            container.read(librarySourceConnectionsProvider).value?.isEmpty ==
            true,
      );
      expect(
        container.read(effectiveLibrarySourceProvider),
        serverMusicSource(library.connection.id),
      );
    },
  );
}
