import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mornye/services/streaming/audio_cache_manager.dart';
import 'package:mornye/services/streaming/buffer_manager.dart';
import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_diagnostics.dart';
import 'package:mornye/services/streaming/stream_manager.dart';
import 'package:mornye/services/streaming/stream_types.dart';
import 'package:synchronized/synchronized.dart';

/// A loopback HTTP server that exposes each active track as a normal audio
/// URL. The platform decoder sees a standard `GET`/`HEAD` + `Range` endpoint;
/// behind it, bytes come from the persistent cache or an authenticated
/// progressive download.
///
/// Sessions belong to one playback generation. Once a newer track is selected,
/// the session is closed and answers `410 Gone`, so a decoder reconnecting for
/// an old track cannot write into or read from the new one.
class AudioStreamServer {
  AudioStreamServer._(this._server) {
    _server.listen((request) => unawaited(_handle(request)));
  }

  static Future<AudioStreamServer> start({InternetAddress? address}) async {
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      0,
    );
    return AudioStreamServer._(server);
  }

  final HttpServer _server;
  final _sessions = <String, AudioStreamSession>{};
  final _random = Random.secure();
  bool _closed = false;

  int get port => _server.port;

  AudioStreamSession openSession({
    required StreamTrack track,
    required StreamOpen opener,
    required PlaybackGeneration generation,
    required GenerationManager generations,
    required CachedAudio audio,
    required StreamManager streams,
    required BufferManager buffers,
    required StreamDiagnostics diagnostics,
    required StreamTimeline timeline,
    void Function()? onWaiting,
    void Function()? onResumed,
  }) {
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final session = AudioStreamSession._(
      id: id,
      origin: 'http://127.0.0.1:${_server.port}',
      track: track,
      opener: opener,
      generation: generation,
      generations: generations,
      audio: audio,
      streams: streams,
      buffers: buffers,
      diagnostics: diagnostics,
      timeline: timeline,
      onWaiting: onWaiting,
      onResumed: onResumed,
    );
    _sessions[id] = session;
    return session;
  }

  Future<void> closeSession(AudioStreamSession session) async {
    _sessions.remove(session.id);
    await session.dispose();
  }

  Future<void> _handle(HttpRequest request) async {
    final id = request.uri.pathSegments.firstOrNull;
    final session = id == null ? null : _sessions[id];
    if (session == null || _closed) {
      try {
        request.response.statusCode = HttpStatus.gone;
      } on StateError {
        return;
      }
      await request.response.close();
      return;
    }
    await session.handle(request);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final session in sessions) {
      await session.dispose();
    }
    await _server.close(force: true);
  }
}

/// One track's byte source: a cache-backed, range-serving view over the
/// authenticated upstream.
class AudioStreamSession {
  AudioStreamSession._({
    required this.id,
    required String origin,
    required this.track,
    required StreamOpen opener,
    required this.generation,
    required this.generations,
    required this.audio,
    required this.streams,
    required this.buffers,
    required this.diagnostics,
    required this.timeline,
    this.onWaiting,
    this.onResumed,
  }) : _opener = opener,
       uri = Uri.parse('$origin/$id');

  final String id;
  final Uri uri;
  final StreamTrack track;
  final PlaybackGeneration generation;
  final GenerationManager generations;
  final CachedAudio audio;
  final StreamManager streams;
  final BufferManager buffers;
  final StreamDiagnostics diagnostics;
  final StreamTimeline timeline;
  final StreamOpen _opener;
  final void Function()? onWaiting;
  final void Function()? onResumed;

  final _fetchLock = Lock();
  _UpstreamFetch? _fetch;
  int? _totalSize;
  Future<int?>? _sizeProbe;
  bool _closed = false;
  bool _firstByteServed = false;
  bool _waiting = false;

  static const int _chunkBytes = 128 * 1024;
  static const int _maxSkipBytes = 1024 * 1024;
  static const Duration _stallTimeout = Duration(seconds: 45);

  bool get isClosed => _closed;
  int? get totalSize => _totalSize;

  /// How many contiguous source bytes are cached from [position].
  int bufferedAheadFrom(int position) =>
      audio.contiguousEndFrom(position) - position;

  Future<void> handle(HttpRequest request) async {
    if (_closed || !generations.isCurrent(generation)) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    int? size;
    try {
      size = await _ensureSize();
    } on Object {
      // The player receives a retryable server error; the next play retries.
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } on StateError {
        return;
      }
      await request.response.close();
      return;
    }
    if (_closed || !generations.isCurrent(generation)) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }

    final header = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    int? endExclusive = size;
    var partial = false;
    if (header != null) {
      final parsed = parseSingleByteRange(header, size);
      if (parsed == null) {
        if (size != null) {
          request.response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          await request.response.close();
          return;
        }
      } else {
        start = parsed.start;
        endExclusive = parsed.end;
        partial = size != null;
      }
    }
    if (size != null) {
      endExclusive ??= size;
      if (start >= size) {
        request.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await request.response.close();
        return;
      }
    }

    final response = request.response;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.contentType = ContentType.parse(track.contentType);
    if (size != null && endExclusive != null) {
      response.headers.contentLength = endExclusive - start;
      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${endExclusive - 1}/$size',
        );
      }
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    var wroteAny = false;
    try {
      await for (final chunk in read(start, endExclusive)) {
        if (_closed || !generations.isCurrent(generation)) break;
        response.add(chunk);
        wroteAny = true;
        await response.flush();
      }
    } on StreamFailure catch (failure) {
      diagnostics.noteFailure(generation, failure);
      if (!wroteAny) {
        try {
          response.statusCode = failure.kind == StreamFailureKind.authentication
              ? HttpStatus.unauthorized
              : HttpStatus.serviceUnavailable;
        } on StateError {
          // Headers were already sent; closing the body is all that is left.
        }
      }
    } on Object {
      // A decoder that disconnects mid-response is normal.
    } finally {
      try {
        await response.close();
      } on Object {
        // The player closed the connection first.
      }
    }
  }

  /// Serves `[start, endExclusive)` from cache, pulling and caching more bytes
  /// as needed.
  Stream<List<int>> read(int start, int? endExclusive) async* {
    var position = start;
    while (endExclusive == null || position < endExclusive) {
      _throwIfObsolete();
      final wantedEnd = endExclusive == null
          ? position + _chunkBytes
          : min(position + _chunkBytes, endExclusive);
      final cached = await audio.read(position, wantedEnd);
      if (cached != null && cached.isNotEmpty) {
        _servedBytes(cached.length);
        position += cached.length;
        yield cached;
        continue;
      }
      await _pullUpstream(position);
      _throwIfObsolete();
    }
    await _maybeFinish();
  }

  Future<void> _pullUpstream(int position) async {
    await _fetchLock.synchronized(() async {
      _throwIfObsolete();
      var attempts = 0;
      while (true) {
        try {
          var fetch = _fetch;
          if (fetch == null ||
              position < fetch.nextOffset ||
              position - fetch.nextOffset > _maxSkipBytes) {
            if (fetch != null) await fetch.close();
            _fetch = null;
            fetch = await _startFetch(position);
          }
          while (fetch.nextOffset < position) {
            final skipped = await fetch.pull(_write);
            if (skipped == 0) {
              throw const StreamFailure(
                StreamFailureKind.unavailable,
                retryable: false,
                detail: 'stream ended early',
              );
            }
          }
          if (position >= fetch.nextOffset) {
            final pulled = await fetch.pull(_write);
            if (pulled == 0) {
              throw const StreamFailure(
                StreamFailureKind.unavailable,
                retryable: false,
                detail: 'stream ended early',
              );
            }
          }
          _noteResumed();
          return;
        } on Object catch (error) {
          final failure = StreamFailure.classify(error);
          if (failure.kind == StreamFailureKind.cancelled ||
              !generations.isCurrent(generation) ||
              _closed) {
            throw failure.asCancelled();
          }
          if (!failure.retryable || attempts >= 2) {
            _noteWaiting();
            rethrow;
          }
          attempts++;
          diagnostics.noteRetry(
            generation,
            reason: 'stream ${failure.kind.name}',
          );
          final fetch = _fetch;
          _fetch = null;
          if (fetch != null) {
            try {
              await fetch.close();
            } on Object {
              // Already closed.
            }
          }
          _noteWaiting();
          final resume = await streams.waitForRetry(
            attempt: attempts,
            generation: generation,
            generations: generations,
          );
          if (!resume) {
            throw const StreamFailure(
              StreamFailureKind.cancelled,
              retryable: false,
            );
          }
        }
      }
    });
  }

  Future<void> _write(int offset, List<int> bytes) async {
    if (_closed || !generations.isCurrent(generation)) {
      throw const StreamFailure(StreamFailureKind.cancelled, retryable: false);
    }
    await audio.write(offset, bytes);
    final written = audio.cachedBytes;
    buffers.onDownloaded(written);
    diagnostics.noteBytes(timeline, bytes.length);
  }

  Future<_UpstreamFetch> _startFetch(int position) async {
    final response = await streams.open(
      opener: _opener,
      generation: generation,
      generations: generations,
      start: position,
      purpose: 'audio',
    );
    diagnostics.markConnected(timeline);
    if (_totalSize == null) {
      final total = response.totalSize;
      if (total != null && total > 0) {
        _totalSize = total;
        audio.meta.totalSize ??= total;
      }
    }
    // A server that ignores Range answers 200 with bytes from offset 0. Skip
    // the prefix so the decoder still receives the offset it asked for; the
    // bytes are discarded rather than cached at the wrong position.
    return _UpstreamFetch(
      response,
      position,
      skip: response.statusCode == HttpStatus.ok ? position : 0,
    );
  }

  void _servedBytes(int bytes) {
    if (!_firstByteServed) {
      _firstByteServed = true;
      diagnostics.markFirstByte(timeline);
    }
    if (_waiting) {
      _waiting = false;
      onResumed?.call();
    }
  }

  void _noteWaiting() {
    if (_waiting || _closed) return;
    _waiting = true;
    onWaiting?.call();
    diagnostics.noteBufferingStart(generation);
  }

  void _noteResumed() {
    if (!_waiting) return;
    _waiting = false;
    onResumed?.call();
    diagnostics.noteBufferingEnd(generation);
  }

  Future<void> _maybeFinish() async {
    final size = _totalSize ?? audio.totalSize;
    if (size == null || !audio.covers(0, size)) return;
    if (audio.isComplete) return;
    final complete = await audio.finish();
    if (complete) {
      diagnostics.noteCacheCompleted(timeline, verified: true);
    }
  }

  /// Uses the server's announcement (a one-byte range probe) to learn the
  /// total length before answering a seekable request.
  Future<int?> _ensureSize() {
    final known = _totalSize ?? track.totalSize ?? audio.totalSize;
    if (known != null && known > 0) {
      _totalSize = known;
      return Future.value(known);
    }
    return _sizeProbe ??= _probeSize();
  }

  Future<int?> _probeSize() async {
    StreamResponse? response;
    try {
      response = await streams.open(
        opener: _opener,
        generation: generation,
        generations: generations,
        start: 0,
        end: 0,
        purpose: 'probe',
      );
      final total = response.totalSize;
      if (total != null && total > 0) {
        _totalSize = total;
        audio.meta.totalSize ??= total;
      }
      if (response.statusCode == HttpStatus.partialContent) {
        // Consume the single probed byte so it seeds the cache.
        var offset = 0;
        await for (final chunk in response.bytes) {
          if (!generations.isCurrent(generation) || _closed) break;
          await _write(offset, chunk);
          offset += chunk.length;
          if (total != null && offset >= total) break;
          if (offset > 0) break;
        }
      } else if (total != null && total > 1) {
        // The server ignored Range and already sent the whole file: keep this
        // response as the first download instead of opening a second one.
        _fetch = _UpstreamFetch(response, 0);
        response = null;
      }
      return total;
    } on StreamFailure {
      return null;
    } finally {
      if (response != null) {
        try {
          await response.close();
        } on Object {
          // Probe response already finished.
        }
      }
    }
  }

  void _throwIfObsolete() {
    if (_closed) {
      throw const StreamFailure(
        StreamFailureKind.cancelled,
        retryable: false,
        detail: 'session closed',
      );
    }
    if (!generations.isCurrent(generation)) {
      throw const StreamFailure(
        StreamFailureKind.cancelled,
        retryable: false,
        detail: 'superseded',
      );
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    final fetch = _fetch;
    _fetch = null;
    if (fetch != null) {
      try {
        await fetch.close();
      } on Object {
        // Best effort; the connection is abandoned.
      }
    }
    // Partial data stays valid and reusable; only the index is written.
    try {
      await audio.flush();
    } on Object {
      // A failed index write only costs a refetch.
    }
  }
}

class _UpstreamFetch {
  _UpstreamFetch(this._response, this.nextOffset, {int skip = 0})
    : _iterator = StreamIterator(
        skip > 0 ? _skipBytes(_response.bytes, skip) : _response.bytes,
      );

  final StreamResponse _response;
  final StreamIterator<List<int>> _iterator;
  int nextOffset;
  bool _done = false;
  Timer? _stallTimer;
  final _stall = Completer<bool>();

  /// Pulls the next upstream chunk, writing it through [write]. Returns the
  /// number of bytes written (0 at a clean end of stream).
  Future<int> pull(
    Future<void> Function(int offset, List<int> bytes) write,
  ) async {
    if (_done) return 0;
    _stallTimer?.cancel();
    _stallTimer = Timer(AudioStreamSession._stallTimeout, () {
      if (!_stall.isCompleted) {
        _stall.completeError(
          const StreamFailure(
            StreamFailureKind.timeout,
            retryable: true,
            detail: 'no audio data',
          ),
        );
      }
    });
    try {
      final hasNext = await Future.any<bool>([
        _iterator.moveNext(),
        _stall.future,
      ]);
      if (!hasNext) {
        _done = true;
        return 0;
      }
      final chunk = _iterator.current;
      if (chunk.isEmpty) return 0;
      final offset = nextOffset;
      nextOffset += chunk.length;
      await write(offset, chunk);
      return chunk.length;
    } on Object {
      _done = true;
      rethrow;
    } finally {
      _stallTimer?.cancel();
    }
  }

  /// Drops [count] leading bytes from a body whose start the server did not
  /// honour, without buffering the discarding bytes.
  static Stream<List<int>> _skipBytes(
    Stream<List<int>> bytes,
    int count,
  ) async* {
    var remaining = count;
    await for (final chunk in bytes) {
      if (remaining <= 0) {
        yield chunk;
      } else if (chunk.length <= remaining) {
        remaining -= chunk.length;
      } else {
        yield chunk.sublist(remaining);
        remaining = 0;
      }
    }
  }

  Future<void> close() async {
    _stallTimer?.cancel();
    try {
      await _iterator.cancel();
    } on Object {
      // The stream may already be finished.
    }
    try {
      await _response.close();
    } on Object {
      // Already closed by the transport.
    }
  }
}
