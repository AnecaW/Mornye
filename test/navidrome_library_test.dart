import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/server_scrobbling.dart';
import 'package:mornye/services/navidrome_library.dart';
import 'package:mornye/services/network_storage_service.dart';

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
}
