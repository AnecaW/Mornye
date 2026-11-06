import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mornye/services/streaming/stream_types.dart';
import 'package:synchronized/synchronized.dart';

/// One contiguous, sequentially written slice of a cached track.
class CacheSegment {
  CacheSegment({
    required this.start,
    required this.length,
    required this.file,
    this.sha256,
  });

  final int start;
  int length;
  final String file;
  String? sha256;

  int get end => start + length;

  bool contains(int offset) => offset >= start && offset < end;

  Map<String, dynamic> toJson() => {
    'start': start,
    'length': length,
    'file': file,
    if (sha256 != null) 'sha256': sha256,
  };

  static CacheSegment? fromJson(Object? value) {
    if (value is! Map) return null;
    final start = value['start'];
    final length = value['length'];
    final file = value['file'];
    if (start is! num || length is! num || file is! String) return null;
    if (start < 0 || length <= 0 || file.isEmpty) return null;
    final hash = value['sha256'];
    return CacheSegment(
      start: start.toInt(),
      length: length.toInt(),
      file: file,
      sha256: hash is String && hash.isNotEmpty ? hash : null,
    );
  }
}

/// The persistent cache index for one track and one account. A partial entry
/// is never represented as complete.
class AudioCacheMeta {
  AudioCacheMeta({
    required this.cacheKey,
    required this.trackId,
    required this.accountId,
    required this.format,
    required this.contentType,
    this.totalSize,
    List<CacheSegment>? segments,
    this.completed = false,
    int? lastAccessMs,
    this.integrity,
  }) : segments = segments ?? [],
       lastAccessMs = lastAccessMs ?? DateTime.now().millisecondsSinceEpoch;

  static const int version = 1;

  final String cacheKey;
  final String trackId;
  final String accountId;
  final String format;
  final String contentType;
  int? totalSize;
  final List<CacheSegment> segments;
  bool completed;
  int lastAccessMs;
  String? integrity;

  ByteRangeSet get ranges => ByteRangeSet([
    for (final segment in segments) ByteSpan(segment.start, segment.length),
  ]);

  int get cachedBytes {
    var total = 0;
    for (final segment in segments) {
      total += segment.length;
    }
    return total;
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'cacheKey': cacheKey,
    'trackId': trackId,
    'accountId': accountId,
    'format': format,
    'contentType': contentType,
    'totalSize': totalSize,
    'segments': [for (final segment in segments) segment.toJson()],
    'completed': completed,
    'lastAccessMs': lastAccessMs,
    if (integrity != null) 'integrity': integrity,
  };

  static AudioCacheMeta? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['version'] != version) return null;
    final cacheKey = json['cacheKey'];
    final trackId = json['trackId'];
    final accountId = json['accountId'];
    if (cacheKey is! String || trackId is! String || accountId is! String) {
      return null;
    }
    final totalSize = json['totalSize'];
    final lastAccess = json['lastAccessMs'];
    return AudioCacheMeta(
      cacheKey: cacheKey,
      trackId: trackId,
      accountId: accountId,
      format: json['format'] is String ? json['format'] as String : '',
      contentType: json['contentType'] is String
          ? json['contentType'] as String
          : 'application/octet-stream',
      totalSize: totalSize is num ? totalSize.toInt() : null,
      segments: [
        for (final raw in (json['segments'] as List? ?? const []))
          ?CacheSegment.fromJson(raw),
      ],
      completed: json['completed'] == true,
      lastAccessMs: lastAccess is num ? lastAccess.toInt() : 0,
      integrity: json['integrity'] is String
          ? json['integrity'] as String
          : null,
    );
  }
}

/// A cache entry opened for reading and progressive writing.
///
/// Bytes written out of order start a new segment; overlapping older segments
/// are dropped so range metadata stays honest. [finish] only marks the entry
/// complete after every byte range is present and each segment's hash matches
/// what was read back from disk.
class CachedAudio {
  CachedAudio._(this._manager, this.track, this.directory, this.meta);

  final AudioCacheManager _manager;
  final StreamTrack track;
  final Directory directory;
  final AudioCacheMeta meta;

  /// Disk writes come from one download at a time; reads may run in parallel.
  final _writeLock = Lock();
  final _metaLock = Lock();
  bool _disposed = false;
  bool _dirty = false;
  DateTime _lastPersist = DateTime.now();

  String get cacheKey => track.cacheKey;
  ByteRangeSet get ranges => meta.ranges;
  int get cachedBytes => meta.cachedBytes;
  bool get isComplete => meta.completed;
  bool get isEmpty => meta.segments.isEmpty;
  int? get totalSize => meta.totalSize;

  /// The end of the contiguous cached run starting at [start].
  int contiguousEndFrom(int start) => meta.ranges.contiguousEndFrom(start);

  bool covers(int start, int endExclusive) =>
      meta.ranges.contains(start, endExclusive - start);

  /// Reads cached bytes, or null when the range is not fully present.
  Future<Uint8List?> read(int start, int endExclusive) async {
    if (_disposed || endExclusive <= start) return null;
    final segment = _segmentContaining(start);
    if (segment == null) return null;
    final availableEnd = segment.end < endExclusive
        ? segment.end
        : endExclusive;
    if (availableEnd <= start) return null;
    final file = File('${directory.path}/${segment.file}');
    RandomAccessFile? handle;
    try {
      handle = await file.open(mode: FileMode.read);
      final actualLength = await handle.length();
      if (actualLength < segment.length) {
        // The file shrank or the write never reached disk: a partial range is
        // not trustworthy, so drop the segment and refetch it.
        await _dropSegment(segment, reason: 'short segment');
        return null;
      }
      await handle.setPosition(start - segment.start);
      final bytes = await handle.read(availableEnd - start);
      if (bytes.length < availableEnd - start) {
        await _dropSegment(segment, reason: 'truncated read');
        return null;
      }
      meta.lastAccessMs = DateTime.now().millisecondsSinceEpoch;
      return bytes;
    } on FileSystemException {
      await _dropSegment(segment, reason: 'unreadable segment');
      return null;
    } finally {
      await handle?.close();
    }
  }

  /// Appends [data] at absolute [start]. Contiguous writes extend the active
  /// segment; a seek writes a new segment and retires an overlapping one.
  Future<void> write(int start, List<int> data) async {
    if (_disposed || data.isEmpty || start < 0) return;
    if (meta.totalSize != null && start + data.length > meta.totalSize!) {
      final allowed = meta.totalSize! - start;
      if (allowed <= 0) return;
      data = data.sublist(0, allowed);
    }
    await _writeLock.synchronized(() async {
      final segment = _appendableSegment(start) ?? await _startSegment(start);
      final file = File('${directory.path}/${segment.file}');
      RandomAccessFile? handle;
      try {
        handle = await file.open(mode: FileMode.writeOnlyAppend);
        await handle.writeFrom(data);
        await handle.flush();
      } on FileSystemException {
        // A failed write leaves the segment length unchanged, so the range is
        // reported missing and will be fetched again.
        await handle?.close();
        await _dropSegment(segment, reason: 'write failed');
        rethrow;
      } finally {
        await handle?.close();
      }
      segment
        ..length += data.length
        ..sha256 = null;
      _dirty = true;
      if (DateTime.now().difference(_lastPersist) >
          const Duration(seconds: 2)) {
        await _persist();
      }
    });
  }

  /// Verifies all bytes and marks the entry complete only when the whole file
  /// is present. Returns whether the entry is now complete and verified.
  Future<bool> finish() async {
    final size = meta.totalSize;
    if (size == null || size <= 0) return false;
    if (!meta.ranges.isComplete(size)) return false;
    final verified = await verify();
    if (!verified) return false;
    meta
      ..completed = true
      ..integrity = 'sha256:${meta.segments.length}';
    await _persist(force: true);
    return true;
  }

  /// Re-reads every segment and compares it with the hash stored when the
  /// segment was last sealed. Failed segments are removed.
  Future<bool> verify() async {
    final clean = <CacheSegment>[];
    for (final segment in List.of(meta.segments)) {
      final file = File('${directory.path}/${segment.file}');
      try {
        final length = await file.length();
        if (length != segment.length) {
          await _deleteSegment(segment);
          continue;
        }
        final digest = await _hashFile(file);
        if (segment.sha256 == null) {
          segment.sha256 = digest;
        } else if (segment.sha256 != digest) {
          await _deleteSegment(segment);
          continue;
        }
        clean.add(segment);
      } on FileSystemException {
        await _deleteSegment(segment);
      }
    }
    if (clean.length != meta.segments.length) {
      meta
        ..segments.clear()
        ..segments.addAll(clean)
        ..completed = false
        ..integrity = null;
      _dirty = true;
      await _persist(force: true);
    }
    final size = meta.totalSize;
    return size != null && meta.ranges.isComplete(size);
  }

  /// Seals segment hashes and writes the index, without requiring completeness.
  Future<void> flush() => _persist(force: true);

  Future<void> _persist({bool force = false}) async {
    if (_disposed && !force) return;
    await _metaLock.synchronized(() async {
      if (!_dirty && !force) return;
      try {
        await directory.create(recursive: true);
        final target = File('${directory.path}/meta.json');
        final staged = File('${target.path}.${_manager.newToken()}.tmp');
        meta.lastAccessMs = DateTime.now().millisecondsSinceEpoch;
        await staged.writeAsString(jsonEncode(meta.toJson()), flush: true);
        await staged.rename(target.path);
        _dirty = false;
        _lastPersist = DateTime.now();
      } on FileSystemException {
        // A missing index only costs a refetch; playback keeps its bytes.
      }
    });
  }

  Future<void> seal() async {
    for (final segment in meta.segments) {
      if (segment.sha256 != null) continue;
      final file = File('${directory.path}/${segment.file}');
      try {
        segment.sha256 = await _hashFile(file);
      } on FileSystemException {
        // Left unsealed; verification will drop it if unreadable.
      }
    }
    _dirty = true;
    await _persist(force: true);
  }

  CacheSegment? _segmentContaining(int offset) {
    for (final segment in meta.segments) {
      if (segment.contains(offset)) return segment;
      if (segment.start > offset) break;
    }
    return null;
  }

  CacheSegment? _appendableSegment(int start) {
    for (final segment in meta.segments) {
      if (segment.end == start) return segment;
    }
    return null;
  }

  Future<CacheSegment> _startSegment(int start) async {
    await directory.create(recursive: true);
    for (final segment in List.of(meta.segments)) {
      if (segment.start == start) {
        await _deleteSegment(segment);
        meta.segments.remove(segment);
      } else if (segment.contains(start)) {
        // Keep the bytes before the new offset instead of discarding the
        // whole segment when a seek restarts inside it.
        await _truncateSegment(segment, start - segment.start);
      }
    }
    final file =
        'seg-${start.toString().padLeft(12, '0')}-'
        '${_manager.newToken().substring(0, 8)}.bin';
    // The segment becomes readable only as bytes are appended; an empty one
    // stays in the index so the next append can extend it.
    final segment = CacheSegment(start: start, length: 0, file: file);
    meta.segments.add(segment);
    meta.segments.sort((a, b) => a.start.compareTo(b.start));
    _dirty = true;
    return segment;
  }

  Future<void> _dropSegment(
    CacheSegment segment, {
    required String reason,
  }) async {
    await _deleteSegment(segment);
    meta
      ..segments.remove(segment)
      ..completed = false
      ..integrity = null;
    _dirty = true;
    _manager.onCorruption?.call(reason);
    await _persist(force: true);
  }

  Future<void> _truncateSegment(CacheSegment segment, int newLength) async {
    if (newLength <= 0) {
      await _deleteSegment(segment);
      meta.segments.remove(segment);
      return;
    }
    final file = File('${directory.path}/${segment.file}');
    try {
      final handle = await file.open(mode: FileMode.writeOnlyAppend);
      try {
        await handle.truncate(newLength);
      } finally {
        await handle.close();
      }
      segment
        ..length = newLength
        ..sha256 = null;
      _dirty = true;
    } on FileSystemException {
      await _deleteSegment(segment);
      meta.segments.remove(segment);
    }
  }

  Future<void> _deleteSegment(CacheSegment segment) async {
    try {
      final file = File('${directory.path}/${segment.file}');
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A locked file is removed by a later cleanup.
    }
  }

  static Future<String> _hashFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> close() async {
    if (_disposed) return;
    await seal();
    _disposed = true;
  }
}

/// Summary of the audio cache, for settings and diagnostics.
class AudioCacheStats {
  const AudioCacheStats({
    required this.entries,
    required this.completedEntries,
    required this.bytes,
    required this.limitBytes,
  });

  final int entries;
  final int completedEntries;
  final int bytes;
  final int limitBytes;

  double get usage => limitBytes <= 0 ? 0 : bytes / limitBytes;
}

/// Persistent, account-scoped progressive audio cache.
///
/// Layout: `<root>/<accountHash>/<trackHash>/meta.json` plus one file per
/// contiguous downloaded segment. The index is written atomically. Entries are
/// evicted least-recently-used first, and pinned entries (the active stream)
/// are never removed.
class AudioCacheManager {
  AudioCacheManager({
    required Directory root,
    this.maxBytes = 2 * 1024 * 1024 * 1024,
    this.verifyOnOpen = true,
    DateTime Function()? clock,
    this.onCorruption,
  }) : _root = root,
       _clock = clock ?? DateTime.now;

  final Directory _root;
  final DateTime Function() _clock;
  final bool verifyOnOpen;
  final void Function(String reason)? onCorruption;
  int maxBytes;

  final _entries = <String, CachedAudio>{};
  final _openLock = Lock();
  final _random = Random.secure();
  bool _disposed = false;

  int get maxCacheBytes => maxBytes;

  String newToken() => List.generate(
    8,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Directory get root => _root;

  /// Opens the cache entry for [track], verifying completed data and
  /// discarding entries that belong to another account or server.
  Future<CachedAudio?> open(StreamTrack track) async {
    if (_disposed) return null;
    return _openLock.synchronized(() async {
      final existing = _entries[track.cacheKey];
      if (existing != null) {
        existing.meta.lastAccessMs = _clock().millisecondsSinceEpoch;
        return existing;
      }
      final directory = _entryDirectory(track);
      final metaFile = File('${directory.path}/meta.json');
      if (!await metaFile.exists()) return null;
      AudioCacheMeta? meta;
      try {
        meta = AudioCacheMeta.fromJson(
          jsonDecode(await metaFile.readAsString()),
        );
      } on FormatException {
        meta = null;
      } on FileSystemException {
        return null;
      }
      if (meta == null ||
          meta.accountId != track.accountId ||
          meta.cacheKey != track.cacheKey) {
        // Never reuse another account's bytes, even if a hash collides.
        await _deleteEntryDirectory(directory);
        return null;
      }
      meta.totalSize ??= track.totalSize;
      final entry = CachedAudio._(this, track, directory, meta);
      await _repairSegments(entry);
      if (meta.completed && verifyOnOpen) {
        final ok = await entry.verify();
        if (!ok && entry.isEmpty) {
          await entry.close();
          await _deleteEntryDirectory(directory);
          onCorruption?.call('completed entry failed verification');
          return null;
        }
      }
      meta.lastAccessMs = _clock().millisecondsSinceEpoch;
      _entries[track.cacheKey] = entry;
      return entry;
    });
  }

  /// Creates an empty cache entry for [track].
  Future<CachedAudio> create(StreamTrack track) async {
    return _openLock.synchronized(() async {
      final existing = _entries[track.cacheKey];
      if (existing != null) return existing;
      final directory = _entryDirectory(track);
      await directory.create(recursive: true);
      final meta = AudioCacheMeta(
        cacheKey: track.cacheKey,
        trackId: track.trackId,
        accountId: track.accountId,
        format: track.format,
        contentType: track.contentType,
        totalSize: track.totalSize,
      );
      final entry = CachedAudio._(this, track, directory, meta);
      _entries[track.cacheKey] = entry;
      await entry.flush();
      return entry;
    });
  }

  /// An existing entry or a new one.
  Future<CachedAudio> openOrCreate(StreamTrack track) async =>
      (await open(track)) ?? create(track);

  Future<void> close(CachedAudio entry) async {
    await entry.close();
    if (identical(_entries[entry.cacheKey], entry)) {
      _entries.remove(entry.cacheKey);
    }
  }

  Future<void> delete(StreamTrack track) async {
    final entry = _entries.remove(track.cacheKey);
    if (entry != null) {
      await entry.close();
    }
    await _deleteEntryDirectory(_entryDirectory(track));
  }

  /// Deletes everything except entries whose cache key is in [keepKeys].
  /// Active streams are unaffected because the caller pins them.
  Future<int> clear({Set<String> keepKeys = const {}}) async {
    if (!await _root.exists()) return 0;
    var removed = 0;
    await for (final account in _root.list()) {
      if (account is! Directory) continue;
      final entries = await account.list().toList();
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final metaFile = File('${entry.path}/meta.json');
        var key = entry.path;
        try {
          final meta = AudioCacheMeta.fromJson(
            jsonDecode(await metaFile.readAsString()),
          );
          if (meta != null) key = meta.cacheKey;
        } on FileSystemException {
          // An unreadable entry is obsolete.
        } on FormatException {
          // An unreadable entry is obsolete.
        }
        if (keepKeys.contains(key)) continue;
        final openEntry = _entries.remove(key);
        if (openEntry != null) await openEntry.close();
        await _deleteEntryDirectory(entry);
        removed++;
      }
      try {
        if (await account.list().isEmpty) await account.delete();
      } on FileSystemException {
        // Another entry may still be writing.
      }
    }
    return removed;
  }

  /// Evicts least-recently-used entries until the cache fits [maxBytes].
  /// Entries in [pinnedKeys] and incomplete entries being written are kept.
  Future<int> evict({Set<String> pinnedKeys = const {}}) async {
    if (!await _root.exists()) return 0;
    final candidates =
        <({Directory directory, String key, int bytes, int access})>[];
    var total = 0;
    await for (final account in _root.list()) {
      if (account is! Directory) continue;
      await for (final entry in account.list()) {
        if (entry is! Directory) continue;
        try {
          final meta = AudioCacheMeta.fromJson(
            jsonDecode(await File('${entry.path}/meta.json').readAsString()),
          );
          if (meta == null) continue;
          final bytes = meta.cachedBytes;
          total += bytes;
          candidates.add((
            directory: entry,
            key: meta.cacheKey,
            bytes: bytes,
            access: meta.lastAccessMs,
          ));
        } on FileSystemException {
          continue;
        } on FormatException {
          continue;
        }
      }
    }
    if (total <= maxBytes) return 0;
    candidates.sort((a, b) => a.access.compareTo(b.access));
    var evicted = 0;
    for (final candidate in candidates) {
      if (total <= maxBytes) break;
      if (pinnedKeys.contains(candidate.key)) continue;
      final openEntry = _entries.remove(candidate.key);
      if (openEntry != null) await openEntry.close();
      await _deleteEntryDirectory(candidate.directory);
      total -= candidate.bytes;
      evicted++;
    }
    return evicted;
  }

  Future<AudioCacheStats> stats() async {
    if (!await _root.exists()) {
      return AudioCacheStats(
        entries: 0,
        completedEntries: 0,
        bytes: 0,
        limitBytes: maxBytes,
      );
    }
    var entries = 0;
    var completed = 0;
    var bytes = 0;
    await for (final account in _root.list()) {
      if (account is! Directory) continue;
      await for (final entry in account.list()) {
        if (entry is! Directory) continue;
        try {
          final meta = AudioCacheMeta.fromJson(
            jsonDecode(await File('${entry.path}/meta.json').readAsString()),
          );
          if (meta == null) continue;
          entries++;
          if (meta.completed) completed++;
          bytes += meta.cachedBytes;
        } on FileSystemException {
          continue;
        } on FormatException {
          continue;
        }
      }
    }
    return AudioCacheStats(
      entries: entries,
      completedEntries: completed,
      bytes: bytes,
      limitBytes: maxBytes,
    );
  }

  Future<void> _repairSegments(CachedAudio entry) async {
    final meta = entry.meta;
    final valid = <CacheSegment>[];
    for (final segment in List.of(meta.segments)) {
      final file = File('${entry.directory.path}/${segment.file}');
      try {
        final length = await file.length();
        if (length < segment.length) {
          // Adopt only bytes that reached disk; the rest must be refetched.
          if (length <= 0) {
            await file.delete();
            continue;
          }
          segment
            ..length = length
            ..sha256 = null;
        } else if (length > segment.length) {
          segment
            ..length = length
            ..sha256 = null;
        }
        if (meta.totalSize != null && segment.end > meta.totalSize!) {
          final allowed = meta.totalSize! - segment.start;
          if (allowed <= 0) {
            await file.delete();
            continue;
          }
          segment
            ..length = allowed
            ..sha256 = null;
        }
        valid.add(segment);
      } on FileSystemException {
        continue;
      }
    }
    if (valid.length != meta.segments.length) {
      meta.segments
        ..clear()
        ..addAll(valid);
      if (meta.totalSize != null && !meta.ranges.isComplete(meta.totalSize!)) {
        meta
          ..completed = false
          ..integrity = null;
      }
      entry._dirty = true;
      await entry.flush();
    }
  }

  Directory _entryDirectory(StreamTrack track) => Directory(
    '${_root.path}/${_safe(track.accountId)}/${_safe(track.cacheKey)}',
  );

  static String _safe(String value) {
    final bytes = utf8.encode(value);
    // Keep paths short enough for every platform while staying collision-safe.
    return bytes.length <= 96
        ? base64Url.encode(bytes).replaceAll('=', '')
        : sha256.convert(bytes).toString();
  }

  Future<void> _deleteEntryDirectory(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Eviction retries once the file is released.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values.toList()) {
      await entry.close();
    }
    _entries.clear();
  }
}
