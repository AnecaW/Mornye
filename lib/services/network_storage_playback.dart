part of 'network_storage_service.dart';

final _playbackLog = AppLogger('NetworkPlayback');

class _PlaybackPrefix {
  _PlaybackPrefix(this.bytes, this.total, this.mime)
    : expires = DateTime.now().add(const Duration(seconds: 30));
  final List<int> bytes;
  final int? total;
  final String mime;
  final DateTime expires;
}

extension NetworkPlaybackPreparation on NetworkStorageService {
  Future<void> invalidatePlaybackPreparation(
    String source, {
    bool corruptCache = false,
  }) async {
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    final c = await connection(host);
    _playbackPrefixes.remove(_audioCacheKey(c, path));
    if (corruptCache) await removeCachedAudio(source);
  }

  /// A small ranged read validates media before it reaches AVPlayer. This
  /// owns its client: cancelling it cannot interrupt the audible stream.
  Future<String> preparePlayback(String source, PlaybackLoad load) async {
    load.check();
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    if (virtualFor(host) != null) return load.wait(resolve(source));
    final c = await load.wait(connection(host));
    final cache = audioCache;
    if (cache != null && path.startsWith('subsonic/song/')) {
      await load.wait(cache.initialize());
      final local = await load.wait(
        cache.lookup(_audioCacheKey(c, path), path.split('.').last),
      );
      if (local != null) {
        cache.pinPlayback(local.path);
        return local.path;
      }
    }
    if (c.protocol == NetworkProtocol.smb) return load.wait(resolve(source));
    final key = _audioCacheKey(c, path);
    final checked = _playbackPrefixes[key];
    if (checked != null && checked.expires.isAfter(DateTime.now())) {
      _playbackLog.d('Reusing bounded stream preparation');
      return load.wait(resolve(source));
    }
    final clock = Stopwatch()..start();
    final client = _client();
    load.onCancel(() => client.close(force: true));
    final deadline = Timer(
      const Duration(seconds: 15),
      () => client.close(force: true),
    );
    StreamIterator<List<int>>? bytes;
    try {
      final target = c.protocol == NetworkProtocol.subsonic
          ? _subsonicMediaTarget(c, path)
          : networkTarget(c, path);
      final response = await load.wait(
        _request(client, c, 'GET', target, range: 'bytes=0-4095'),
      );
      load.check();
      final status = response.statusCode;
      if (status != 200 && status != 206) {
        throw PlaybackFailure(
          status == 401 || status == 403
              ? PlaybackFailureKind.authentication
              : status == 404 || status == 410
              ? PlaybackFailureKind.missing
              : PlaybackFailureKind.network,
          status: status,
        );
      }
      final mime = response.headers.contentType?.mimeType ?? '';
      if (response.headers
              .value(HttpHeaders.contentEncodingHeader)
              ?.toLowerCase() ==
          'gzip') {
        throw const PlaybackFailure(PlaybackFailureKind.invalidAudio);
      }
      if (status == 206 &&
          !RegExp(r'^bytes 0-\d+/[\d*]+$').hasMatch(
            response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
          )) {
        throw const PlaybackFailure(PlaybackFailureKind.invalidAudio);
      }
      bytes = StreamIterator(response.timeout(const Duration(seconds: 10)));
      final prefix = <int>[];
      while (prefix.length < 4096 && await load.wait(bytes.moveNext())) {
        prefix.addAll(bytes.current.take(4096 - prefix.length));
      }
      load.check();
      if (c.protocol == NetworkProtocol.subsonic && mime.contains('json')) {
        try {
          final document = _subsonicMap(jsonDecode(utf8.decode(prefix)));
          final code = _subsonicMap(
            _subsonicMap(document['subsonic-response'])['error'],
          )['code'];
          if (code == 40 || code == 41 || code == 50) {
            throw const PlaybackFailure(PlaybackFailureKind.authentication);
          }
          if (code == 70) {
            throw const PlaybackFailure(PlaybackFailureKind.missing);
          }
        } on FormatException {
          /* Invalid error document is never audio. */
        }
      }
      if (mime.startsWith('text/') ||
          mime.contains('json') ||
          mime.contains('xml')) {
        throw const PlaybackFailure(PlaybackFailureKind.invalidAudio);
      }
      final text = utf8
          .decode(prefix.take(256).toList(), allowMalformed: true)
          .trimLeft()
          .toLowerCase();
      if (prefix.length < 4 ||
          text.startsWith('<') ||
          text.startsWith('{') ||
          text.startsWith('[')) {
        throw const PlaybackFailure(PlaybackFailureKind.invalidAudio);
      }
      final contentRange = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      final total = status == 206
          ? int.tryParse(contentRange?.split('/').last ?? '')
          : response.contentLength > 0
          ? response.contentLength
          : null;
      while (_playbackPrefixes.length >= 32) {
        _playbackPrefixes.remove(_playbackPrefixes.keys.first);
      }
      _playbackPrefixes[key] = _PlaybackPrefix(
        List.unmodifiable(prefix),
        total,
        mime.startsWith('audio/') ? mime : networkContentType(path),
      );
      _playbackLog.d(
        'Stream checked: status=$status bytes=${prefix.length} elapsedMs=${clock.elapsedMilliseconds}',
      );
      setReachable(host, reachable: true);
      return await load.wait(resolve(source));
    } on PlaybackSuperseded {
      rethrow;
    } catch (error) {
      load.check();
      throw PlaybackFailure.classify(error);
    } finally {
      deadline.cancel();
      client.close(force: true);
      await bytes?.cancel();
    }
  }

  _NetworkRead? _playbackPrefixRead(
    NetworkConnection c,
    String path,
    String? range,
  ) {
    if (range == null) return null;
    final prefix = _playbackPrefixes[_audioCacheKey(c, path)];
    if (prefix == null ||
        prefix.total == null ||
        prefix.expires.isBefore(DateTime.now())) {
      return null;
    }
    try {
      final part = networkByteRange(range, prefix.total!);
      if (part.end >= prefix.bytes.length) return null;
      return (
        status: 206,
        headers: {
          HttpHeaders.contentTypeHeader: prefix.mime,
          HttpHeaders.contentLengthHeader: '${part.end - part.start + 1}',
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.contentRangeHeader:
              'bytes ${part.start}-${part.end}/${prefix.total}',
        },
        bytes: Stream.value(prefix.bytes.sublist(part.start, part.end + 1)),
        discard: () async {},
        close: () async {},
      );
    } on FormatException {
      return null;
    }
  }
}
