import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns expendable audio only. Permanent downloads never enter this directory.
/// Completed files are published atomically; partial files are never playable.
class NetworkAudioCache {
  NetworkAudioCache({Future<Directory> Function()? directory})
    : _directory =
          directory ??
          (() async => Directory(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'network_audio_cache',
            ),
          ));

  final Future<Directory> Function() _directory;
  final _pending = <String, Future<void>>{};
  final _verified = <String, ({int size, DateTime modified})>{};
  final _fills = <String, NetworkCacheFill>{};
  Future<void> _background = Future.value();
  bool enabled = true;
  bool wifiOnly = true;
  bool preferOffline = true;
  int upcoming = 2;
  int maxBytes = 1024 * 1024 * 1024;
  Future<void>? _initializing;
  int _epoch = 0;
  final _playingPaths = <String>[];
  void pinPlayback(String path) {
    _playingPaths.remove(path);
    _playingPaths.add(path);
    while (_playingPaths.length > 2) {
      _playingPaths.removeAt(0);
    }
  }

  NetworkCacheFill? filling(String key) => _fills[key];
  void reportLength(String key, int? length) => _fills[key]?.setLength(length);

  Future<void> initialize() => _initializing ??= () async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('audio_cache_enabled') ?? true;
    wifiOnly = prefs.getBool('audio_cache_wifi') ?? true;
    preferOffline = prefs.getBool('audio_cache_offline') ?? true;
    upcoming = (prefs.getInt('audio_cache_upcoming') ?? 2).clamp(0, 10);
    maxBytes = (prefs.getInt('audio_cache_bytes') ?? maxBytes).clamp(
      128 * 1024 * 1024,
      16 * 1024 * 1024 * 1024,
    );
    // A terminated process cannot run a fill's finally block. Its unpublished
    // spools must not accumulate indefinitely across application restarts.
    try {
      final directory = await _directory();
      if (await directory.exists()) {
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is File && entry.path.endsWith('.part')) {
            await entry.delete();
          }
        }
      }
    } on FileSystemException {
      /* Cleanup failure must not block playback. */
    }
  }();

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool('audio_cache_enabled', enabled),
      prefs.setBool('audio_cache_wifi', wifiOnly),
      prefs.setBool('audio_cache_offline', preferOffline),
      prefs.setInt('audio_cache_upcoming', upcoming),
      prefs.setInt('audio_cache_bytes', maxBytes),
    ]);
    await trim();
  }

  String _name(String key, String suffix) =>
      '${sha256.convert(utf8.encode(key))}.${RegExp(r'^[a-zA-Z0-9]+$').hasMatch(suffix) ? suffix : 'audio'}';

  Future<File?> lookup(String key, String suffix, {bool touch = true}) async {
    final file = File(p.join((await _directory()).path, _name(key, suffix)));
    if (!await file.exists()) return null;
    final proof = File('${file.path}.proof');
    try {
      final stat = await file.stat();
      final verified = _verified[file.path];
      if (stat.size <= 0 ||
          verified == null ||
          verified.size != stat.size ||
          verified.modified != stat.modified) {
        final expected = jsonDecode(await proof.readAsString()) as Map;
        if (expected['bytes'] != stat.size ||
            expected['sha256'] !=
                (await sha256.bind(file.openRead()).first).toString()) {
          throw const FormatException('Unverified audio cache');
        }
      }
      if (touch) await file.setLastModified(DateTime.now());
      final current = await file.stat();
      _verified[file.path] = (size: current.size, modified: current.modified);
      return file;
    } on Object {
      _verified.remove(file.path);
      try {
        await file.delete();
      } on FileSystemException {
        /* Expendable cache only. */
      }
      try {
        await proof.delete();
      } on FileSystemException {
        /* Already gone. */
      }
      return null;
    }
  }

  /// At most one foreground and one background cache fill. Playback itself
  /// never waits for a fill; an incomplete entry continues to use streaming.
  Future<void> fetch(
    String key,
    String suffix,
    Future<void> Function(File, int) download, {
    bool background = false,
    bool manual = false,
  }) async {
    await initialize();
    if ((!enabled && !manual) || await lookup(key, suffix) != null) return;
    if (wifiOnly) {
      final networks = await Connectivity().checkConnectivity();
      if (!networks.contains(ConnectivityResult.wifi) &&
          !networks.contains(ConnectivityResult.ethernet)) {
        if (manual) {
          throw StateError('Cache is restricted to Wi-Fi or Ethernet');
        }
        return;
      }
    }
    final existing = _pending[key];
    if (existing != null) return existing;
    // Do not let rapid queue changes create unbounded foreground downloads.
    if (!background && _pending.length >= 2) return;
    final epoch = _epoch;
    Future<void> fill() async {
      if (epoch != _epoch || (!enabled && !manual)) return;
      final dir = await _directory();
      await dir.create(recursive: true);
      final target = File(p.join(dir.path, _name(key, suffix)));
      final partial = File('${target.path}.part');
      final fill = NetworkCacheFill(partial, target);
      _fills[key] = fill;
      try {
        if (await target.exists()) return;
        await trim();
        await download(partial, maxBytes);
        if (epoch != _epoch || (!enabled && !manual)) return;
        if (await partial.length() <= 0 || await partial.length() > maxBytes) {
          throw const FileSystemException('Audio exceeds cache limit');
        }
        final digest = (await sha256.bind(partial.openRead()).first).toString();
        final length = await partial.length();
        await File('${target.path}.proof').writeAsString(
          jsonEncode({'bytes': length, 'sha256': digest}),
          flush: true,
        );
        await partial.rename(target.path);
        fill.published = true;
        await trim(keep: target.path);
        fill.finish();
      } catch (error, stack) {
        fill.fail(error, stack);
        rethrow;
      } finally {
        if (!fill.finished) {
          fill.fail(StateError('Cache fill cancelled'), StackTrace.current);
        }
        _fills.remove(key);
        if (await partial.exists()) await partial.delete();
        if (!fill.published) {
          final proof = File('${target.path}.proof');
          if (await proof.exists()) await proof.delete();
        }
      }
    }

    final operation = background ? _background.then((_) => fill()) : fill();
    if (background) _background = operation.catchError((Object _) {});
    _pending[key] = operation;
    try {
      await operation;
    } finally {
      _pending.remove(key);
    }
  }

  Future<int> size() async {
    final dir = await _directory();
    if (!await dir.exists()) return 0;
    var bytes = 0;
    await for (final item in dir.list(followLinks: false)) {
      if (item is File && !item.path.endsWith('.proof'))
        bytes += await item.length();
    }
    return bytes;
  }

  Future<void> remove(String key, String suffix) async {
    final file = File(p.join((await _directory()).path, _name(key, suffix)));
    _verified.remove(file.path);
    if (await file.exists()) await file.delete();
    final proof = File('${file.path}.proof');
    if (await proof.exists()) await proof.delete();
  }

  Future<void> clear() async {
    _epoch++;
    _verified.clear();
    await Future.wait(
      _pending.values.toList().map((f) => f.catchError((Object _) {})),
    );
    final dir = await _directory();
    if (!await dir.exists()) return;
    await for (final item in dir.list(followLinks: false)) {
      if (item is File && !item.path.endsWith('.part')) await item.delete();
    }
  }

  Future<void> trim({String? keep}) async {
    final dir = await _directory();
    if (!await dir.exists()) return;
    final files = <({File file, FileStat stat})>[];
    var bytes = 0;
    await for (final item in dir.list(followLinks: false)) {
      if (item is! File ||
          item.path.endsWith('.part') ||
          item.path.endsWith('.proof'))
        continue;
      final stat = await item.stat();
      files.add((file: item, stat: stat));
      bytes += stat.size;
    }
    files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    for (final item in files) {
      if (bytes <= maxBytes) break;
      if (item.file.path == keep || _playingPaths.contains(item.file.path)) {
        continue;
      }
      try {
        await item.file.delete();
        _verified.remove(item.file.path);
        final proof = File('${item.file.path}.proof');
        if (await proof.exists()) await proof.delete();
        bytes -= item.stat.size;
      } on FileSystemException {
        /* A playing file can be locked on Windows. */
      }
    }
  }
}

/// A shared progressive read of one original file. The player serves byte
/// ranges from this spool instead of downloading the same audio a second time.
class NetworkCacheFill {
  NetworkCacheFill(this.partial, this.target) {
    done.future.ignore();
  }
  final File partial, target;
  final ready = Completer<int?>();
  final done = Completer<void>();
  bool published = false, finished = false;
  Object? error;
  File get file => published ? target : partial;
  void setLength(int? value) {
    if (!ready.isCompleted) {
      ready.complete(value != null && value > 0 ? value : null);
    }
  }

  void finish() {
    finished = true;
    setLength(null);
    done.complete();
  }

  void fail(Object value, StackTrace stack) {
    if (finished) return;
    finished = true;
    error = value;
    setLength(null);
    done.completeError(value, stack);
  }

  Stream<List<int>> read(int start, int end) async* {
    var offset = start;
    while (offset < end) {
      if (error != null) {
        throw const HttpException('Cached audio download interrupted');
      }
      final current = file;
      int length;
      try {
        length = await current.length();
      } on FileSystemException {
        // The atomic rename may occur between choosing and opening the path.
        if (published) continue;
        length = 0;
      }
      final available = length - offset;
      if (available > 0) {
        final count = available.clamp(0, (end - offset).clamp(0, 256 * 1024));
        try {
          final bytes = await current
              .openRead(offset, offset + count)
              .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
          if (bytes.isNotEmpty) {
            offset += bytes.length;
            yield bytes;
          }
        } on FileSystemException {
          if (!published) rethrow;
        }
      } else {
        if (finished) throw const HttpException('Cached audio ended early');
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  }
}
