import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/navidrome_library.dart';
import 'package:mornye/services/network_storage_service.dart';

/// Counts forward listening, bounded by elapsed time, excluding seeks/pauses.
class ServerListeningSession {
  ServerListeningSession({required this.submit, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final Future<void> Function(String source, DateTime started) submit;
  final DateTime Function() _now;
  String? _source;
  DateTime? _started, _lastTick;
  Duration _last = Duration.zero, _heard = Duration.zero;
  bool _submitted = false;
  bool isForSource(String source) => _source == source;
  void begin(String source) {
    _source = source;
    _started = _now();
    _lastTick = _started;
    _last = Duration.zero;
    _heard = Duration.zero;
    _submitted = false;
  }

  Future<void> tick(
    Duration position, {
    required bool playing,
    Duration? duration,
  }) async {
    final now = _now();
    final elapsed = _lastTick == null
        ? Duration.zero
        : now.difference(_lastTick!);
    _lastTick = now;
    final delta = position - _last;
    _last = position;
    if (!playing ||
        delta <= Duration.zero ||
        delta > const Duration(seconds: 2) ||
        elapsed <= Duration.zero) {
      return;
    }
    _heard += delta < elapsed ? delta : elapsed;
    final seconds = duration == null || duration.inSeconds <= 0
        ? 240
        : (duration.inSeconds / 2).clamp(1, 240).ceil();
    if (!_submitted &&
        _heard >= Duration(seconds: seconds) &&
        _source != null) {
      _submitted = true;
      try {
        await submit(_source!, _started!);
      } catch (_) {
        _submitted = false;
        rethrow;
      }
    }
  }
}

/// Durable, account-bound submissions. Preserve timestamps on at-least-once
/// replay: Subsonic supplies no idempotency key for lost acknowledgements.
class ServerScrobbleOutbox {
  ServerScrobbleOutbox({NetworkStorageService? storage})
    : _storage = storage ?? NetworkStorageService.instance;
  static const _key = 'subsonic_scrobble_outbox_v1';
  static final instance = ServerScrobbleOutbox();
  final NetworkStorageService _storage;
  Future<void> _tail = Future.value();
  Future<void>? _flushing;
  String _account(NavidromeLibrary library) {
    final c = library.connection;
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              c.id,
              c.address,
              c.username,
              c.password,
              c.subsonicAuth.name,
              c.apiKey,
            ]),
          ),
        )
        .toString();
  }

  List<Map<String, dynamic>> _rows(String? raw) {
    if (raw == null) {
      return [];
    }
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<int> pendingCount() async =>
      _rows((await SharedPreferences.getInstance()).getString(_key)).length;
  Future<void> enqueue(String source, DateTime started) {
    final operation = _tail.then((_) async {
      final target = await NavidromeLibrary.forSource(
        source,
        storage: _storage,
      );
      if (target == null) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final pending = _rows(prefs.getString(_key));
      final id = '$source/${started.millisecondsSinceEpoch}';
      if (!pending.any((e) => e['key'] == id)) {
        pending.add({
          'key': id,
          'source': source,
          'time': started.millisecondsSinceEpoch,
          'account': _account(target.library),
        });
      }
      if (!await prefs.setString(_key, jsonEncode(pending))) {
        throw StateError('Could not save playback submission');
      }
    });
    _tail = operation.catchError((Object _) {});
    return operation.then((_) => flush());
  }

  Future<void> flush() =>
      _flushing ??= _flush().whenComplete(() => _flushing = null);
  Future<void> _flush() async {
    await _tail;
    final prefs = await SharedPreferences.getInstance();
    final snapshot = _rows(prefs.getString(_key));
    for (final row in snapshot) {
      try {
        final target = await NavidromeLibrary.forSource(
          row['source'] as String,
          storage: _storage,
        );
        if (target == null || _account(target.library) != row['account']) {
          continue;
        }
        await target.library.scrobble(
          target.id,
          submission: true,
          time: DateTime.fromMillisecondsSinceEpoch(row['time'] as int),
        );
        final removal = _tail.then((_) async {
          final current = _rows(prefs.getString(_key))
            ..removeWhere((e) => e['key'] == row['key']);
          if (!await prefs.setString(_key, jsonEncode(current))) {
            throw StateError('Could not acknowledge playback submission');
          }
        });
        _tail = removal.catchError((Object _) {});
        await removal;
      } catch (_) {
        /* Retain failed submissions for playback/resume retry. */
      }
    }
  }

  Future<void> nowPlaying(String source) async {
    try {
      final target = await NavidromeLibrary.forSource(
        source,
        storage: _storage,
      );
      if (target != null) {
        await target.library.scrobble(
          target.id,
          submission: false,
          time: DateTime.now(),
        );
      }
    } catch (_) {
      /* Now-playing is transient; only submissions are journaled. */
    }
    await flush();
  }
}
