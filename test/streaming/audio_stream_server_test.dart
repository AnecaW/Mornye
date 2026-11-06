import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/audio_cache_manager.dart';
import 'package:mornye/services/streaming/audio_stream_server.dart';
import 'package:mornye/services/streaming/buffer_manager.dart';
import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_diagnostics.dart';
import 'package:mornye/services/streaming/stream_manager.dart';
import 'package:mornye/services/streaming/stream_types.dart';

class _FakeUpstream {
  _FakeUpstream._(this._server, this.data, this.ignoreRange);

  static Future<_FakeUpstream> start(
    List<int> data, {
    bool ignoreRange = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _FakeUpstream._(server, data, ignoreRange);
    server.listen((request) => upstream._serve(request));
    return upstream;
  }

  final HttpServer _server;
  final List<int> data;
  final bool ignoreRange;
  int requests = 0;
  int? lastStart;

  String get url => 'http://127.0.0.1:${_server.port}/audio.flac';

  Future<void> _serve(HttpRequest request) async {
    requests++;
    if (ignoreRange) {
      lastStart = 0;
      final response = request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.parse('audio/flac')
        ..headers.contentLength = data.length;
      response.add(data);
      await response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = data.length;
    if (range != null) {
      final parsed = parseSingleByteRange(range, data.length);
      if (parsed == null) {
        request.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${data.length}',
          );
        await request.response.close();
        return;
      }
      start = parsed.start;
      end = parsed.end;
    }
    lastStart = start;
    final response = request.response;
    response
      ..statusCode = HttpStatus.partialContent
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(HttpHeaders.contentTypeHeader, 'audio/flac')
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/${data.length}',
      )
      ..headers.contentLength = end - start;
    response.add(data.sublist(start, end));
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

StreamOpen _opener(_FakeUpstream upstream) => (start, end) async {
  final client = HttpClient();
  final request = await client.openUrl('GET', Uri.parse(upstream.url));
  request.headers.set(
    HttpHeaders.rangeHeader,
    'bytes=$start-${end == null ? '' : end - 1}',
  );
  final response = await request.close();
  final headers = <String, String>{};
  response.headers.forEach((name, values) {
    headers[name] = values.join(',');
  });
  return StreamResponse(
    statusCode: response.statusCode,
    headers: headers,
    bytes: response,
    close: () async => client.close(force: true),
  );
};

Future<({int status, HttpHeaders headers, List<int> bytes})> _get(
  Uri uri, {
  String? range,
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final builder = BytesBuilder();
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return (
      status: response.statusCode,
      headers: response.headers,
      bytes: builder.takeBytes(),
    );
  } finally {
    client.close(force: true);
  }
}

StreamTrack _track(int size) => StreamTrack(
  source: 'network://account/subsonic/song/one.flac',
  cacheKey: 'account/one',
  accountId: 'account',
  trackId: 'one',
  format: 'flac',
  contentType: 'audio/flac',
  totalSize: size,
  label: 'one',
);

void main() {
  late Directory root;
  late AudioCacheManager cache;
  late _FakeUpstream upstream;
  late AudioStreamServer server;
  late GenerationManager generations;
  late StreamDiagnostics diagnostics;
  late StreamManager streams;
  late BufferManager buffers;
  late StreamTrack track;
  late AudioStreamSession session;
  late List<int> data;

  setUp(() async {
    data = List<int>.generate(300000, (index) => index % 251);
    root = await Directory.systemTemp.createTemp('mornye-stream-test-');
    cache = AudioCacheManager(root: root);
    upstream = await _FakeUpstream.start(data);
    server = await AudioStreamServer.start();
    generations = GenerationManager();
    diagnostics = StreamDiagnostics();
    streams = StreamManager(
      diagnostics: diagnostics,
      initialBackoff: const Duration(milliseconds: 2),
    );
    buffers = BufferManager();
    track = _track(data.length);
    final audio = await cache.create(track);
    final timeline = diagnostics.begin(
      generations.current,
      label: track.cacheKey,
      cacheHit: false,
    );
    session = server.openSession(
      track: track,
      opener: _opener(upstream),
      generation: generations.current,
      generations: generations,
      audio: audio,
      streams: streams,
      buffers: buffers,
      diagnostics: diagnostics,
      timeline: timeline,
    );
  });

  tearDown(() async {
    await server.close();
    await upstream.close();
    await cache.dispose();
    await streams.dispose();
    await diagnostics.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'serves a requested range with standard headers and caches it',
    () async {
      final first = await _get(session.uri, range: 'bytes=0-65535');
      expect(first.status, HttpStatus.partialContent);
      expect(first.bytes, data.sublist(0, 65536));
      expect(
        first.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-65535/${data.length}',
      );
      expect(first.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      final entry = await cache.open(track);
      expect(entry, isNotNull);
      expect(entry!.ranges.contains(0, 65536), isTrue);
    },
  );

  test('a second read of the same range is served from cache', () async {
    await _get(session.uri, range: 'bytes=0-65535');
    final requests = upstream.requests;
    final second = await _get(session.uri, range: 'bytes=0-65535');
    expect(second.status, HttpStatus.partialContent);
    expect(second.bytes, data.sublist(0, 65536));
    expect(upstream.requests, requests);
  });

  test(
    'seeking an uncached track fetches from the target offset only',
    () async {
      final seek = await _get(session.uri, range: 'bytes=200000-200255');
      expect(seek.status, HttpStatus.partialContent);
      expect(seek.bytes, data.sublist(200000, 200256));
      expect(upstream.lastStart, 200000);
      expect(upstream.requests, lessThanOrEqualTo(4));
      final entry = await cache.open(track);
      expect(entry!.ranges.contains(200000, 256), isTrue);
      expect(entry.ranges.contains(0, 1000), isFalse);
    },
  );

  test('answers HEAD with the total length', () async {
    final head = await _get(session.uri, method: 'HEAD');
    expect(head.status, HttpStatus.ok);
    expect(
      head.headers.value(HttpHeaders.contentLengthHeader),
      '${data.length}',
    );
  });

  test('rejects a stale generation with 410 Gone', () async {
    generations.advance('skip');
    final stale = await _get(session.uri);
    expect(stale.status, HttpStatus.gone);
  });

  test(
    'an upstream that ignores Range is aligned to the requested offset',
    () async {
      final ignoring = await _FakeUpstream.start(data, ignoreRange: true);
      final audio = await cache.open(track);
      final ignoringSession = server.openSession(
        track: track,
        opener: _opener(ignoring),
        generation: generations.advance('ignoring range'),
        generations: generations,
        audio: audio!,
        streams: streams,
        buffers: buffers,
        diagnostics: diagnostics,
        timeline: diagnostics.begin(
          generations.current,
          label: track.cacheKey,
          cacheHit: false,
        ),
      );
      final seek = await _get(
        ignoringSession.uri,
        range: 'bytes=200000-200255',
      );
      expect(seek.status, HttpStatus.partialContent);
      expect(seek.bytes, data.sublist(200000, 200256));
      expect(ignoring.lastStart, 0);
      final entry = await cache.open(track);
      expect(entry!.ranges.contains(200000, 256), isTrue);
      expect(entry.ranges.contains(0, 1000), isFalse);
      await server.closeSession(ignoringSession);
      await ignoring.close();
    },
  );

  test('a reopened session reuses partially cached bytes', () async {
    await _get(session.uri, range: 'bytes=0-4095');
    await server.closeSession(session);
    final cached = await cache.open(track);
    expect(cached, isNotNull);
    final requests = upstream.requests;
    final newSession = server.openSession(
      track: track,
      opener: _opener(upstream),
      generation: generations.advance('reopen'),
      generations: generations,
      audio: cached!,
      streams: streams,
      buffers: buffers,
      diagnostics: diagnostics,
      timeline: diagnostics.begin(
        generations.current,
        label: track.cacheKey,
        cacheHit: true,
      ),
    );
    final again = await _get(newSession.uri, range: 'bytes=0-4095');
    expect(again.bytes, data.sublist(0, 4096));
    expect(upstream.requests, requests);
    session = newSession;
  });
}
