import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playable_media.dart';

List<Map<String, dynamic>> subsonicRows(Object? value) => value is List
    ? value
          .whereType<Map<Object?, Object?>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList()
    : const [];
Map<String, dynamic> subsonicObject(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

class ServerPlaylist {
  ServerPlaylist(Map<String, dynamic> data) : data = Map.unmodifiable(data);
  final Map<String, dynamic> data;
  String get id => data['id'].toString();
  String get name => data['name']?.toString() ?? '';
  bool get readOnly => data['readonly'] == true || data['readOnly'] == true;
  List<Map<String, dynamic>> get tracks => subsonicRows(data['entry']);
  List<String> get songIds => tracks.map((e) => e['id'].toString()).toList();
  String get revision => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            data['changed'],
            name,
            data['comment'],
            data['public'],
            songIds,
          ]),
        ),
      )
      .toString();
}

class ServerConflict implements Exception {
  const ServerConflict();
  @override
  String toString() =>
      'This playlist changed on the server. Refresh before editing.';
}

/// One account owns every identifier, cache entry and mutation in this client.
class NavidromeLibrary {
  NavidromeLibrary(
    this.connection, {
    NetworkStorageService? storage,
    this.keepAlive = false,
  }) : storage = storage ?? NetworkStorageService.instance;
  final NetworkConnection connection;
  final NetworkStorageService storage;
  final bool keepAlive;
  final _clients = <bool, SubsonicClient>{};
  void close() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }

  // App-lifetime event bus; listeners own and cancel their subscriptions.
  // ignore: close_sinks
  static final _changes = StreamController<String>.broadcast();
  static Stream<String> get changes => _changes.stream;
  static final _writes = <String, Future<void>>{};

  Future<T> _withClient<T>(
    Future<T> Function(SubsonicClient) action, {
    bool fresh = false,
  }) async {
    final client = keepAlive
        ? _clients.putIfAbsent(
            fresh,
            () => storage.openSubsonic(connection, fresh: fresh),
          )
        : storage.openSubsonic(connection, fresh: fresh);
    try {
      return await action(client);
    } finally {
      if (!keepAlive) client.close();
    }
  }

  Future<Map<String, dynamic>> read(
    String method, [
    Map<String, String> args = const {},
    bool fresh = false,
  ]) => _withClient((c) => c.request(method, args), fresh: fresh);
  Future<Map<String, dynamic>> write(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final result = await _withClient((c) => c.live(method, args));
    if (method != 'scrobble') _changes.add(connection.id);
    return result;
  }

  Future<List<Map<String, dynamic>>> artists({bool fresh = false}) async => [
    for (final index in subsonicRows(
      subsonicObject((await read('getArtists', {}, fresh))['artists'])['index'],
    ))
      ...subsonicRows(index['artist']),
  ];
  Future<List<Map<String, dynamic>>> albums({
    String type = 'alphabeticalByName',
    int offset = 0,
    String? genre,
    bool fresh = false,
  }) async => subsonicRows(
    subsonicObject(
      (await read('getAlbumList2', {
        'type': type,
        'size': '100',
        'offset': '$offset',
        'genre': ?genre,
      }, fresh))['albumList2'],
    )['album'],
  );
  Future<List<Map<String, dynamic>>> playlists({bool fresh = false}) async =>
      subsonicRows(
        subsonicObject(
          (await read('getPlaylists', {}, fresh))['playlists'],
        )['playlist'],
      );
  Future<ServerPlaylist> playlist(String id, {bool fresh = false}) async =>
      ServerPlaylist(
        subsonicObject(
          (await read('getPlaylist', {'id': id}, fresh))['playlist'],
        ),
      );
  Future<List<Map<String, dynamic>>> songs(
    String method,
    Map<String, String> args,
    String container,
    String field, {
    bool fresh = false,
  }) async => subsonicRows(
    subsonicObject((await read(method, args, fresh))[container])[field],
  );
  Future<Map<String, dynamic>> starred({bool fresh = false}) async =>
      subsonicObject((await read('getStarred2', {}, fresh))['starred2']);
  Future<void> star(String id, String kind, bool value) async {
    if (!const {'song', 'album', 'artist'}.contains(kind)) {
      throw ArgumentError.value(kind);
    }
    await write(value ? 'star' : 'unstar', {
      switch (kind) {
        'album' => 'albumId',
        'artist' => 'artistId',
        _ => 'id',
      }: id,
    });
  }

  Future<void> rate(String id, int rating) async {
    if (rating < 0 || rating > 5) throw RangeError.range(rating, 0, 5);
    await write('setRating', {'id': id, 'rating': '$rating'});
  }

  Future<bool> toggleSong(String id) async {
    final data = subsonicObject(
      (await read('getSong', {'id': id}, true))['song'],
    );
    final value = data['starred'] == null;
    await star(id, 'song', value);
    return value;
  }

  Future<void> createPlaylist(
    String name, [
    List<String> songs = const [],
  ]) async {
    if (name.trim().isEmpty) throw ArgumentError('A playlist name is required');
    await write('createPlaylist', {
      'name': name.trim(),
      if (songs.isNotEmpty) 'songId': songs,
    });
  }

  Future<void> editPlaylist(
    ServerPlaylist base, {
    String? name,
    List<String>? songs,
    bool delete = false,
  }) async {
    if (base.readOnly) throw StateError('This server playlist is read-only');
    final key = '${connection.id}/${base.id}';
    final before = _writes[key] ?? Future<void>.value();
    final operation = before.then((_) async {
      final current = await playlist(base.id, fresh: true);
      if (base.revision != current.revision) throw const ServerConflict();
      if (delete) {
        await write('deletePlaylist', {'id': base.id});
      } else if (songs != null) {
        // createPlaylist with playlistId replaces the entire ordered membership
        // in a single server operation, preserving duplicate songs and indices.
        await write('createPlaylist', {'playlistId': base.id, 'songId': songs});
      } else if (name != null) {
        if (name.trim().isEmpty) {
          throw ArgumentError('A playlist name is required');
        }
        await write('updatePlaylist', {
          'playlistId': base.id,
          'name': name.trim(),
        });
      }
    });
    final tail = operation.then<void>((_) {}, onError: (Object _) {});
    _writes[key] = tail;
    try {
      await operation;
    } finally {
      if (identical(_writes[key], tail)) _writes.remove(key);
    }
  }

  Future<List<Map<String, dynamic>>> radios({bool fresh = false}) async =>
      subsonicRows(
        subsonicObject(
          (await read(
            'getInternetRadioStations',
            {},
            fresh,
          ))['internetRadioStations'],
        )['internetRadioStation'],
      );
  Future<void> saveRadio(String name, String url, {String? id}) async {
    final uri = Uri.tryParse(url);
    if (name.trim().isEmpty ||
        uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Enter a station name and an HTTP(S) stream URL without credentials',
      );
    }
    await write(
      id == null ? 'createInternetRadioStation' : 'updateInternetRadioStation',
      {'name': name.trim(), 'streamUrl': url, 'id': ?id},
    );
  }

  Future<void> deleteRadio(String id) async {
    await write('deleteInternetRadioStation', {'id': id});
  }

  Future<void> scrobble(
    String id, {
    required bool submission,
    required DateTime time,
  }) async {
    await write('scrobble', {
      'id': id,
      'submission': '$submission',
      'time': '${time.millisecondsSinceEpoch}',
    });
  }

  PlayableMedia playable(Map<String, dynamic> data) {
    final song = SubsonicSong(data);
    final source = NetworkStorageService.source(connection.id, song.path);
    return PlayableMedia(
      id: source,
      source: source,
      title: song.title,
      artist: song.artist,
      album: song.album,
      networkArtworkSource: song.coverPath == null
          ? null
          : NetworkStorageService.source(connection.id, song.coverPath!),
      duration: data['duration'] is num
          ? Duration(milliseconds: ((data['duration'] as num) * 1000).round())
          : null,
      format: song.format,
      bitDepth: (data['bitDepth'] as num?)?.toInt(),
      sampleRate: (data['samplingRate'] as num?)?.toInt(),
    );
  }

  static Future<({NavidromeLibrary library, String id})?> forSource(
    String? source, {
    NetworkStorageService? storage,
  }) async {
    final uri = Uri.tryParse(source ?? '');
    if (uri == null ||
        uri.scheme != 'network' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final id = subsonicSongIdFromPath(uri.pathSegments.join('/'));
    if (id == null) return null;
    final service = storage ?? NetworkStorageService.instance;
    final connection = (await service.connections())
        .where(
          (c) => c.id == uri.host && c.protocol == NetworkProtocol.subsonic,
        )
        .firstOrNull;
    return connection == null
        ? null
        : (library: NavidromeLibrary(connection, storage: service), id: id);
  }
}
