import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Bounded, account-scoped REST metadata. Only hashed account identities reach
/// disk, and authentication failures never fall back to cached responses.
class SubsonicResponseCache {
  SubsonicResponseCache({
    Future<Directory> Function()? directory,
    this.ttl = const Duration(minutes: 5),
    this.maxBytes = 64 * 1024 * 1024,
    this.maxEntries = 256,
  }) : _directory =
           directory ??
           (() async => Directory(
             p.join(
               (await getApplicationSupportDirectory()).path,
               'subsonic_metadata',
             ),
           ));
  final Future<Directory> Function() _directory;
  final Duration ttl;
  final int maxBytes, maxEntries;
  final _pending = <String, Future<Map<String, dynamic>>>{};
  final _epochs = <String, int>{};
  static const _methods = {
    'getGenres',
    'getStarred2',
    'getInternetRadioStations',
    'search3',
    'getSongsByGenre',
    'getArtists',
    'getArtist',
    'getAlbumList2',
    'getAlbum',
    'getSong',
    'getPlaylists',
    'getPlaylist',
    'getMusicFolders',
  };
  static bool isCacheable(String method) => _methods.contains(method);

  String _account(String account) =>
      sha256.convert(utf8.encode(account)).toString();

  Future<Map<String, dynamic>> request(
    String account,
    String method,
    Map<String, String> arguments,
    Future<Map<String, dynamic>> Function() fetch, {
    bool fresh = false,
  }) async {
    if (!_methods.contains(method)) return fetch();
    final sorted = Map.fromEntries(
      arguments.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final owner = _account(account);
    final epoch = _epochs[owner] ?? 0;
    bool active() => (_epochs[owner] ?? 0) == epoch;
    final name =
        '${owner}_${sha256.convert(utf8.encode('$method/${jsonEncode(sorted)}'))}.json';
    if (fresh) return _read(name, fetch, fresh: true, active: active);
    final existing = _pending[name];
    if (existing != null) return existing;
    final operation = _read(name, fetch, active: active);
    _pending[name] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_pending[name], operation)) _pending.remove(name);
    }
  }

  Future<Map<String, dynamic>> _read(
    String name,
    Future<Map<String, dynamic>> Function() fetch, {
    bool fresh = false,
    required bool Function() active,
  }) async {
    File? file;
    Map<String, dynamic>? cached;
    try {
      file = File(p.join((await _directory()).path, name));
      if (await file.exists() && await file.length() <= 4 * 1024 * 1024) {
        final stored = jsonDecode(await file.readAsString()) as Map;
        cached = Map<String, dynamic>.from(stored['response'] as Map);
        if (cached['status'] != 'ok') {
          cached = null;
          throw const FormatException('Invalid cached response');
        }
        final time = DateTime.fromMillisecondsSinceEpoch(
          stored['saved'] as int,
        );
        if (!fresh && DateTime.now().difference(time) < ttl) {
          await file.setLastModified(DateTime.now());
          return cached;
        }
      }
    } catch (_) {
      /* Missing or corrupt metadata is fetched anew. */
    }
    Map<String, dynamic> value;
    try {
      value = await fetch();
    } on SocketException {
      if (cached != null && !fresh) return cached;
      rethrow;
    } on TimeoutException {
      if (cached != null && !fresh) return cached;
      rethrow;
    }
    if (file != null && active()) {
      try {
        final encoded = jsonEncode({
          'saved': DateTime.now().millisecondsSinceEpoch,
          'response': value,
        });
        if (utf8.encode(encoded).length <= 4 * 1024 * 1024) {
          await file.parent.create(recursive: true);
          final temporary = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
          );
          try {
            await temporary.writeAsString(encoded, flush: true);
            await temporary.rename(file.path);
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
          await _trim(file.parent);
        }
      } catch (_) {
        /* A cache write cannot fail a successful API request. */
      }
    }
    return value;
  }

  Future<void> invalidate(String account) async {
    final owner = _account(account);
    _epochs[owner] = (_epochs[owner] ?? 0) + 1;
    _pending.removeWhere((key, _) => key.startsWith('${owner}_'));
    try {
      final directory = await _directory();
      if (!await directory.exists()) return;
      final prefix = '${_account(account)}_';
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && p.basename(entry.path).startsWith(prefix)) {
          await entry.delete();
        }
      }
    } on FileSystemException {
      /* Explicit scans always bypass the cache. */
    }
  }

  Future<void> _trim(Directory directory) async {
    final entries = <({File file, FileStat stat})>[];
    var bytes = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final stat = await entry.stat();
      entries.add((file: entry, stat: stat));
      bytes += stat.size;
    }
    entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var count = entries.length;
    for (final entry in entries) {
      if (count <= maxEntries && bytes <= maxBytes) break;
      await entry.file.delete();
      count--;
      bytes -= entry.stat.size;
    }
  }
}
