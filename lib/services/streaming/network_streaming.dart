import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/streaming/audio_cache_manager.dart';
import 'package:mornye/services/streaming/audio_stream_server.dart';
import 'package:mornye/services/streaming/buffer_manager.dart';
import 'package:mornye/services/streaming/download_manager.dart';
import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/playback_state_machine.dart';
import 'package:mornye/services/streaming/recently_played_sync.dart';
import 'package:mornye/services/streaming/stream_diagnostics.dart';
import 'package:mornye/services/streaming/stream_manager.dart';
import 'package:mornye/services/streaming/stream_types.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('AudioStreaming');

/// The authenticated source behind a `network://` identity.
abstract interface class StreamingSource {
  /// Whether this source serves the identity, decided without I/O.
  bool owns(String source);

  /// Reads the track facts the cache and transport need, or null when the
  /// identity is not handled.
  Future<StreamTrack?> describe(String source);

  /// An opener for authenticated byte reads from [track].
  StreamOpen openerFor(StreamTrack track);

  /// Reports a play to the server when it supports play history.
  Future<void> scrobble(
    String source,
    String songId, {
    required bool submission,
    int? timeMs,
  });
}

/// Limits and switches for streaming and caching.
class StreamingEngineConfig {
  const StreamingEngineConfig({
    this.maxCacheBytes = 2 * 1024 * 1024 * 1024,
    this.maxConcurrentDownloads = 2,
    this.prefetchAhead = 2,
    this.verifyCacheOnOpen = true,
    this.prefetchEnabled = true,
  });

  final int maxCacheBytes;
  final int maxConcurrentDownloads;

  /// How many upcoming tracks may be prepared. Never the whole queue.
  final int prefetchAhead;
  final bool verifyCacheOnOpen;
  final bool prefetchEnabled;
}

/// Coordinates generations, the persistent cache, progressive downloads and
/// the local stream server for network playback.
///
/// The existing player remains the queue and transport authority; this engine
/// only decides where bytes come from, guarantees that stale work is discarded,
/// and reports safe diagnostics.
class NetworkStreaming {
  NetworkStreaming._({
    required this.source,
    required AudioStreamServer server,
    required StreamingEngineConfig config,
    required Directory cacheRoot,
  }) : _server = server,
       config = config {
    generations = GenerationManager();
    diagnostics = StreamDiagnostics(
      onLog: (message) => _log.d(message),
      slowFirstAudio: const Duration(seconds: 3),
    );
    cache = AudioCacheManager(
      root: cacheRoot,
      maxBytes: config.maxCacheBytes,
      verifyOnOpen: config.verifyCacheOnOpen,
      onCorruption: (reason) => _log.w('Audio cache: $reason'),
    );
    streams = StreamManager(diagnostics: diagnostics);
    buffers = BufferManager();
    downloads = DownloadManager(
      cache: cache,
      streams: streams,
      generations: generations,
      maxConcurrent: config.maxConcurrentDownloads,
      onLog: (message) => _log.d(message),
    );
    recentlyPlayed = RecentlyPlayedSync(
      send: _sendScrobble,
      onLog: (message) => _log.d('Recent: $message'),
    );
    state = PlaybackStateMachine(
      onTransition: (from, to, reason) => _log.d(
        'state ${from.name} -> ${to.name}'
        '${reason.isEmpty ? '' : ' ($reason)'}',
      ),
      onRejected: (from, to, reason) => _log.d(
        'state rejected ${from.name} -> ${to.name}'
        '${reason.isEmpty ? '' : ' ($reason)'}',
      ),
    );
    _generationSubscription = generations.changes.listen(_onGenerationChanged);
  }

  static Future<NetworkStreaming> create({
    required StreamingSource source,
    required Directory cacheRoot,
    StreamingEngineConfig config = const StreamingEngineConfig(),
  }) async {
    final server = await AudioStreamServer.start();
    return NetworkStreaming._(
      source: source,
      server: server,
      config: config,
      cacheRoot: cacheRoot,
    );
  }

  final StreamingSource source;
  final StreamingEngineConfig config;
  final AudioStreamServer _server;

  late final GenerationManager generations;
  late final StreamDiagnostics diagnostics;
  late final AudioCacheManager cache;
  late final StreamManager streams;
  late final BufferManager buffers;
  late final DownloadManager downloads;
  late final RecentlyPlayedSync recentlyPlayed;
  late final PlaybackStateMachine state;
  late final StreamSubscription<PlaybackGeneration> _generationSubscription;

  AudioStreamSession? _session;
  StreamTrack? _currentTrack;
  String? _currentSource;
  StreamTimeline? _timeline;
  int _bitrateBytesPerSecond = 24000;
  bool _wantsPlayback = false;
  bool _disposed = false;
  final _prefetching = <String>{};

  String? get currentSource => _currentSource;
  StreamTrack? get currentTrack => _currentTrack;
  PlaybackPhase get phase => state.phase;

  Set<String> get activeCacheKeys => {
    if (_currentTrack != null) _currentTrack!.cacheKey,
    ...downloads.activeCacheKeys,
  };

  bool supports(String source) => !_disposed && this.source.owns(source);

  /// Creates (or reuses) a stream for [networkSource] and returns its loopback
  /// URL. Each call is a new generation: anything still in flight for the
  /// previous selection is closed before this session starts.
  Future<String> resolve(String networkSource) async {
    if (_disposed) {
      throw const StreamFailure(StreamFailureKind.cancelled, retryable: false);
    }
    final track = await source.describe(networkSource);
    if (track == null) {
      throw const StreamFailure(
        StreamFailureKind.unavailable,
        retryable: false,
        detail: 'unsupported network source',
      );
    }
    final generation = generations.advance('select');
    downloads.cancelPrefetches();
    final previous = _session;
    _session = null;
    if (previous != null) await _server.closeSession(previous);

    state.reset(reason: 'new selection');
    state.transition(PlaybackPhase.resolvingTrack, reason: 'select');
    buffers.reset();

    CachedAudio? entry;
    try {
      entry = await cache.open(track);
    } on Object {
      entry = null;
    }
    final cacheHit = entry != null && entry.cachedBytes > 0;
    final timeline = diagnostics.begin(
      generation,
      label: track.cacheKey,
      cacheHit: cacheHit,
    );
    if (entry != null && entry.isComplete) {
      diagnostics.noteCacheCompleted(timeline, verified: true);
    }
    final audio = entry ?? await cache.create(track);
    _currentTrack = track;
    _currentSource = networkSource;
    _timeline = timeline;
    _bitrateBytesPerSecond = _estimateBitrate(track);
    _wantsPlayback = false;

    final session = _server.openSession(
      track: track,
      opener: source.openerFor(track),
      generation: generation,
      generations: generations,
      audio: audio,
      streams: streams,
      buffers: buffers,
      diagnostics: diagnostics,
      timeline: timeline,
      onWaiting: () => _onSessionWaiting(generation),
      onResumed: () => _onSessionResumed(generation),
    );
    _session = session;
    state.transition(PlaybackPhase.connecting, reason: 'stream ready');
    unawaited(
      cache.evict(pinnedKeys: activeCacheKeys).catchError((Object error) {
        _log.w('Cache eviction failed: $error');
        return 0;
      }),
    );
    return session.uri.toString();
  }

  /// Prepares up to [StreamingEngineConfig.prefetchAhead] upcoming tracks at
  /// low priority. Failures are invisible: prefetching never affects playback.
  void prefetchUpcoming(Iterable<String> upcoming) {
    if (_disposed || !config.prefetchEnabled) return;
    final seen = <String>{};
    var scheduled = 0;
    for (final source in upcoming) {
      if (scheduled >= config.prefetchAhead) break;
      if (source == _currentSource || !this.source.owns(source)) continue;
      if (!seen.add(source)) continue;
      scheduled++;
      unawaited(_prefetch(source));
    }
  }

  Future<void> _prefetch(String networkSource) async {
    if (_prefetching.contains(networkSource)) return;
    _prefetching.add(networkSource);
    try {
      final track = await source.describe(networkSource);
      if (track == null || _disposed || networkSource == _currentSource) return;
      final existing = await cache.open(track);
      if (existing != null && existing.isComplete) return;
      final outcome = await downloads.schedule(
        DownloadJob(
          track: track,
          opener: source.openerFor(track),
          generation: generations.current,
          priority: DownloadPriority.next,
          label: 'prefetch',
        ),
      );
      if (outcome.completed && outcome.verified) {
        await cache.evict(pinnedKeys: activeCacheKeys);
      }
    } on Object {
      // Prefetch is opportunistic; the next play still streams normally.
    } finally {
      _prefetching.remove(networkSource);
    }
  }

  /// Feeds real playback state from the player. Starts Recently Played sync and
  /// drives the visible phase without touching queue logic.
  void reportPlayback({
    required String? source,
    required Duration position,
    Duration? duration,
    required bool playing,
    required bool ended,
  }) {
    if (_disposed) return;
    final track = _currentTrack;
    if (source == null ||
        track == null ||
        source != _currentSource ||
        !this.source.owns(source)) {
      return;
    }
    recentlyPlayed.update(
      source: source,
      songId: track.trackId,
      position: position,
      duration: duration,
      playing: playing,
      ended: ended,
    );
    _wantsPlayback = playing;
    if (playing) {
      if (state.phase != PlaybackPhase.playing) {
        state.transition(PlaybackPhase.playing, reason: 'audio output');
      }
      if (_timeline case final timeline? when timeline.firstAudioAt == null) {
        diagnostics.markFirstAudio(timeline);
      }
      buffers.onDecoded(
        position: position,
        bitrateBytesPerSecond: _bitrateBytesPerSecond,
      );
      downloads.resumePrefetch();
    } else if (ended) {
      state.transition(PlaybackPhase.idle, reason: 'track ended');
      if (_timeline case final timeline?) diagnostics.markFinished(timeline);
      unawaited(recentlyPlayed.flush());
    } else if (state.phase == PlaybackPhase.playing ||
        state.phase == PlaybackPhase.seeking ||
        state.phase == PlaybackPhase.buffering ||
        state.phase == PlaybackPhase.reconnecting) {
      // Includes a seek or rebuffer while paused: the phase must settle back
      // to paused rather than staying stuck in the intermediate state.
      state.transition(PlaybackPhase.paused, reason: 'paused');
    }
  }

  /// A seek is served from cache or a new upstream range; prefetch yields until
  /// audio is flowing again.
  void reportSeek(String? source) {
    if (_disposed || source != _currentSource) return;
    buffers.onSeek();
    downloads.pausePrefetch();
    if (state.phase != PlaybackPhase.seeking) {
      state.transition(PlaybackPhase.seeking, reason: 'seek');
    }
  }

  /// Ends streaming work immediately, e.g. when the player closes.
  void cancel(String reason) {
    if (_disposed) return;
    generations.advance(reason);
    downloads.cancelAll();
    final session = _session;
    _session = null;
    if (session != null) unawaited(_server.closeSession(session));
    _wantsPlayback = false;
    state.reset(reason: reason);
  }

  /// Removes cached audio except what a live stream or download is using.
  Future<int> clearCache() => cache.clear(keepKeys: activeCacheKeys);

  Future<AudioCacheStats> cacheStats() => cache.stats();

  Future<void> setCacheLimit(int bytes) async {
    if (bytes <= 0) return;
    cache.maxBytes = bytes;
    await cache.evict(pinnedKeys: activeCacheKeys);
  }

  void _onSessionWaiting(PlaybackGeneration generation) {
    if (!generations.isCurrent(generation) || !_wantsPlayback) return;
    buffers.onStall();
    downloads.pausePrefetch();
    if (state.phase != PlaybackPhase.buffering) {
      state.transition(PlaybackPhase.buffering, reason: 'buffer low');
    }
  }

  void _onSessionResumed(PlaybackGeneration generation) {
    if (!generations.isCurrent(generation) || !_wantsPlayback) return;
    downloads.resumePrefetch();
    if (state.phase == PlaybackPhase.buffering ||
        state.phase == PlaybackPhase.recovering ||
        state.phase == PlaybackPhase.reconnecting ||
        state.phase == PlaybackPhase.seeking) {
      state.transition(PlaybackPhase.playing, reason: 'data available');
    }
  }

  void _onGenerationChanged(PlaybackGeneration next) {
    final session = _session;
    if (session != null && !generations.isCurrent(session.generation)) {
      _session = null;
      unawaited(_server.closeSession(session));
    }
  }

  Future<void> _sendScrobble(
    String source,
    String songId, {
    required bool submission,
    int? timeMs,
  }) => this.source.scrobble(
    source,
    songId,
    submission: submission,
    timeMs: timeMs,
  );

  int _estimateBitrate(StreamTrack track) {
    final size = track.totalSize;
    final duration = track.duration;
    if (size != null && duration != null && duration.inMilliseconds > 0) {
      final rate = size * 1000 / duration.inMilliseconds;
      if (rate.isFinite && rate > 0) {
        return rate.clamp(8000, 4 * 1024 * 1024).round();
      }
    }
    return 24000;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _generationSubscription.cancel();
    downloads.dispose();
    await recentlyPlayed.dispose();
    await _server.close();
    await cache.dispose();
    await streams.dispose();
    await diagnostics.dispose();
    await generations.dispose();
  }

  static NetworkStreaming? _active;
  static Future<NetworkStreaming?>? _initializing;

  /// The process-wide engine, or null when the cache directory is unavailable
  /// (playback then uses the existing direct proxy).
  static NetworkStreaming? get active => _active;

  static Future<NetworkStreaming?> ensureInitialized() {
    final active = _active;
    if (active != null) return Future.value(active);
    return _initializing ??= _initialize();
  }

  static Future<NetworkStreaming?> _initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      final engine = await create(
        source: SubsonicStreamingSource(),
        cacheRoot: Directory('${support.path}/audio_stream_cache'),
      );
      _active = engine;
      return engine;
    } on Object catch (error) {
      _log.w('Audio streaming cache unavailable: ${error.runtimeType}');
      _initializing = null;
      return null;
    }
  }
}

/// The user's own Subsonic/Navidrome server, authenticated with their stored
/// credentials through [NetworkStorageService]. Credentials never leave that
/// service and never appear in a URL handed to the player.
class SubsonicStreamingSource implements StreamingSource {
  SubsonicStreamingSource([NetworkStorageService? storage])
    : _storage = storage ?? NetworkStorageService.instance;

  final NetworkStorageService _storage;

  @override
  bool owns(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'network') return false;
    return subsonicSongIdFromPath(uri.pathSegments.join('/')) != null;
  }

  @override
  Future<StreamTrack?> describe(String source) async {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'network' || uri.host.isEmpty) {
      return null;
    }
    final path = uri.pathSegments.join('/');
    final songId = subsonicSongIdFromPath(path);
    if (songId == null) return null;
    final NetworkConnection connection;
    try {
      connection = await _storage.connection(uri.host);
    } on StateError {
      return null;
    }
    if (connection.protocol != NetworkProtocol.subsonic) return null;
    final format = path
        .split('/')
        .last
        .split('.')
        .skip(1)
        .join('.')
        .toLowerCase();
    // The account hash includes the server address and user name, so two
    // accounts (or two servers) can never share cached bytes.
    final accountId = sha256
        .convert(
          utf8.encode(
            '${connection.id}\n${connection.address}\n${connection.username}',
          ),
        )
        .toString();
    final cacheKey = sha256
        .convert(utf8.encode('$accountId\n$songId\n$format'))
        .toString();
    return StreamTrack(
      source: source,
      cacheKey: cacheKey,
      accountId: accountId,
      trackId: songId,
      format: format,
      contentType: networkContentType(path),
      label: cacheKey,
    );
  }

  @override
  StreamOpen openerFor(StreamTrack track) => (start, end) async {
    final handle = await _storage.openStreamRead(
      track.source,
      start: start,
      end: end,
    );
    if (handle.statusCode >= 400) {
      await handle.discard();
      await handle.close();
      throw StreamFailure.classifyStatus(handle.statusCode);
    }
    final total =
        handle.totalSize ??
        (track.totalSize != null && track.totalSize! > 0
            ? track.totalSize
            : null);
    return StreamResponse(
      statusCode: handle.statusCode,
      headers: handle.headers,
      totalSize: total,
      bytes: handle.bytes,
      close: () async {
        try {
          await handle.close();
        } on Object {
          // Already released by the transport.
        }
      },
    );
  };

  @override
  Future<void> scrobble(
    String source,
    String songId, {
    required bool submission,
    int? timeMs,
  }) async {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'network') return;
    final connection = await _storage.connection(uri.host);
    if (connection.protocol != NetworkProtocol.subsonic) return;
    final client = _storage.openSubsonic(connection);
    try {
      await client.scrobble(
        songId,
        submission: submission,
        time: timeMs == null
            ? null
            : min(timeMs, DateTime.now().millisecondsSinceEpoch),
      );
    } finally {
      client.close();
    }
  }
}
