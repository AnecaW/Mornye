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

class _SharedPlaybackPreparation {
  _SharedPlaybackPreparation(this.load);
  final PlaybackLoad load;
  late final Future<String> result;
  int subscribers = 0;
  bool completed = false;
}

Duration? _retryAfter(String? header) {
  if (header == null) return null;
  var seconds = int.tryParse(header);
  if (seconds == null) {
    try {
      seconds = HttpDate.parse(
        header,
      ).difference(DateTime.now().toUtc()).inSeconds;
    } on FormatException {
      return null;
    }
  }
  return Duration(seconds: seconds.clamp(0, 15));
}

extension NetworkPlaybackPreparation on NetworkStorageService {
  Future<void> invalidatePlaybackPreparation(
    String source, {
    bool corruptCache = false,
  }) async {
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    final c = await connection(host);
    _playbackPrefixes.remove(_audioCacheKey(c, path));
    _playbackProfiles[_audioCacheKey(c, '')]?.stalled();
    if (corruptCache) await removeCachedAudio(source);
  }

  /// A small ranged read validates media before it reaches AVPlayer. This
  /// shares the server pool; cancellation aborts only this request, never the audible stream.
  Future<String> preparePlayback(String source, PlaybackLoad load) async {
    load.check();
    load.mark(PlaybackPreparationStage.resolvingSource);
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    if (virtualFor(host) != null)
      return load.wait(resolve(source, forPlayback: true));
    final connectionValue = await load.wait(connection(host));
    final key = _audioCacheKey(connectionValue, path);
    var shared = _playbackPreparations[key];
    if (shared == null || shared.load.cancelled) {
      shared = _SharedPlaybackPreparation(
        PlaybackLoad(requestId: load.requestId, bitrate: load.bitrate),
      );
      _playbackPreparations[key] = shared;
      final work = shared;
      work.result = _preparePlayback(source, work.load);
      void completed() {
        work.completed = true;
        if (identical(_playbackPreparations[key], work))
          _playbackPreparations.remove(key);
      }

      unawaited(
        work.result.then<void>(
          (_) => completed(),
          onError: (Object _, StackTrace __) => completed(),
        ),
      );
    }
    final work = shared;
    work.subscribers++;
    load.mark(work.load.stage);
    var detached = false;
    void detach() {
      if (detached) return;
      detached = true;
      work.subscribers--;
      if (work.subscribers == 0 && !work.completed) work.load.cancel();
    }

    final unregister = load.onCancel(detach);
    try {
      final result = await load.wait(work.result);
      load.bufferPolicy = work.load.bufferPolicy;
      load.receivedBytes = work.load.receivedBytes;
      load.requests += work.load.requests;
      return result;
    } finally {
      unregister();
      detach();
    }
  }

  Future<String> _preparePlayback(String source, PlaybackLoad load) async {
    load.check();
    final (:host, :path) = NetworkStorageService._sourceParts(source);
    if (virtualFor(host) != null)
      return load.wait(resolve(source, forPlayback: true));
    final c = await load.wait(connection(host));
    final cache = audioCache;
    if (cache != null && path.startsWith('subsonic/song/')) {
      await load.wait(cache.initialize());
      final local = await load.wait(
        cache.lookup(_audioCacheKey(c, path), path.split('.').last),
      );
      if (local != null) {
        cache.pinPlayback(local.path);
        _playbackLog.d(
          'Playback request=${load.requestId} cache=verified trackHash=${source.hashCode}',
        );
        return local.path;
      }
    }
    if (c.protocol == NetworkProtocol.smb)
      return load.wait(resolve(source, forPlayback: true));
    final key = _audioCacheKey(c, path);
    final profileKey = _audioCacheKey(c, '');
    final profile = _playbackProfiles.putIfAbsent(
      profileKey,
      PlaybackNetworkProfile.new,
    );
    while (_playbackProfiles.length > 16) {
      _playbackProfiles.remove(_playbackProfiles.keys.first);
    }
    load.bufferPolicy = profile.policyFor(load.bitrate);
    final probeBytes = profile.probeBytes(load.bitrate);
    final checked = _playbackPrefixes[key];
    if (checked != null && checked.expires.isAfter(DateTime.now())) {
      _playbackLog.d(
        'Playback request=${load.requestId} cache=prefix trackHash=${source.hashCode}',
      );
      return load.wait(resolve(source, forPlayback: true));
    }
    final clock = Stopwatch()..start();
    final transferClock = Stopwatch();
    Duration? firstByte;
    final client = _readClient(c);
    HttpClientRequest? activeRequest;
    final removeCancellation = load.onCancel(() => activeRequest?.abort());
    var deadlineExpired = false;
    final deadline = Timer(const Duration(seconds: 15), () {
      deadlineExpired = true;
      activeRequest?.abort(
        const SocketException('Playback preparation timed out'),
      );
    });
    StreamIterator<List<int>>? bytes;
    HttpClientResponse? responseToDiscard;
    try {
      final target = c.protocol == NetworkProtocol.subsonic
          ? _subsonicMediaTarget(c, path)
          : networkTarget(c, path);
      load.mark(PlaybackPreparationStage.connecting);
      load.requests++;
      final response = await load.wait(
        _request(
          client,
          c,
          'GET',
          target,
          range: 'bytes=0-${probeBytes - 1}',
          onRequest: (request) {
            activeRequest = request;
            if (deadlineExpired) {
              request.abort();
              throw const PlaybackFailure(PlaybackFailureKind.timeout);
            }
            if (load.cancelled) request.abort();
            load.check();
          },
        ),
      );
      responseToDiscard = response;
      load.check();
      final status = response.statusCode;
      load.mark(PlaybackPreparationStage.validatingStream, status: status);
      if (status != 200 && status != 206) {
        throw PlaybackFailure(
          status == 401 || status == 403
              ? PlaybackFailureKind.authentication
              : status == 404 || status == 410
              ? PlaybackFailureKind.missing
              : status == 408 || status == 504
              ? PlaybackFailureKind.timeout
              : PlaybackFailureKind.network,
          status: status,
          retryAfter: _retryAfter(
            response.headers.value(HttpHeaders.retryAfterHeader),
          ),
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
      responseToDiscard = null;
      final prefix = <int>[];
      while (prefix.length < probeBytes && await load.wait(bytes.moveNext())) {
        firstByte ??= clock.elapsed;
        if (!transferClock.isRunning) transferClock.start();
        prefix.addAll(bytes.current.take(probeBytes - prefix.length));
      }
      load.check();
      // A completed bounded range returns its connection to the pool. Never
      // drain an ignored range: that would download the rest of the file.
      if (response.contentLength == prefix.length) {
        await load.wait(bytes.moveNext());
      }
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
        'Playback request=${load.requestId} stream status=$status bytes=${prefix.length} elapsedMs=${clock.elapsedMilliseconds} trackHash=${source.hashCode}',
      );
      profile.observe(
        firstByte: firstByte ?? clock.elapsed,
        bytes: prefix.length,
        transfer: transferClock.elapsed,
      );
      load.bufferPolicy = profile.policyFor(load.bitrate);
      load.receivedBytes = prefix.length;
      setReachable(host, reachable: true);
      return await load.wait(resolve(source, forPlayback: true));
    } on PlaybackSuperseded {
      rethrow;
    } catch (error) {
      load.check();
      if (deadlineExpired)
        throw const PlaybackFailure(PlaybackFailureKind.timeout);
      throw PlaybackFailure.classify(error);
    } finally {
      deadline.cancel();
      removeCancellation();
      await bytes?.cancel();
      // StreamIterator does not subscribe before moveNext. Header rejection
      // therefore needs an explicit response subscription and cancellation.
      if (responseToDiscard != null) await _discardResponse(responseToDiscard);
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
