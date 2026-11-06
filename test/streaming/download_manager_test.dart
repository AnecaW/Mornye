import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/audio_cache_manager.dart';
import 'package:mornye/services/streaming/download_manager.dart';
import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_diagnostics.dart';
import 'package:mornye/services/streaming/stream_manager.dart';
import 'package:mornye/services/streaming/stream_types.dart';

StreamTrack _track(String id, int size) => StreamTrack(
  source: 'network://account/subsonic/song/$id.flac',
  cacheKey: 'account/$id',
  accountId: 'account',
  trackId: id,
  format: 'flac',
  contentType: 'audio/flac',
  totalSize: size,
  label: id,
);

List<int> _bytes(int length) =>
    List<int>.generate(length, (index) => index % 251);

Stream<List<int>> _chunks(List<int> data, int chunk, Duration delay) async* {
  for (var offset = 0; offset < data.length; offset += chunk) {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    yield data.sublist(offset, min(offset + chunk, data.length));
  }
}

StreamOpen _opener(
  List<int> data, {
  Duration delay = Duration.zero,
  void Function(int start)? onOpen,
}) => (start, end) async {
  onOpen?.call(start);
  final limit = end == null ? data.length : min(end, data.length);
  return StreamResponse(
    statusCode: 200,
    headers: {'content-length': '${data.length}'},
    totalSize: data.length,
    bytes: _chunks(data.sublist(start, limit), 64, delay),
    close: () async {},
  );
};

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition did not become true');
}

void main() {
  late Directory root;
  late AudioCacheManager cache;
  late GenerationManager generations;
  late StreamManager streams;
  late DownloadManager downloads;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mornye-download-');
    cache = AudioCacheManager(root: root);
    generations = GenerationManager();
    streams = StreamManager(
      diagnostics: StreamDiagnostics(),
      initialBackoff: const Duration(milliseconds: 2),
      maxBackoff: const Duration(milliseconds: 5),
    );
    downloads = DownloadManager(
      cache: cache,
      streams: streams,
      generations: generations,
      maxConcurrent: 1,
    );
  });

  tearDown(() async {
    await downloads.dispose();
    await cache.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('honours priority: foreground, next, then background', () async {
    final release = Completer<void>();
    final started = <String>[];
    final blocker = DownloadJob(
      track: _track('blocker', 100),
      opener: (start, end) async {
        started.add('blocker');
        await release.future;
        return StreamResponse(
          statusCode: 200,
          headers: const {'content-length': '100'},
          totalSize: 100,
          bytes: Stream.value(_bytes(100)),
          close: () async {},
        );
      },
      generation: generations.current,
      priority: DownloadPriority.foreground,
    );
    final blockerDone = downloads.schedule(blocker);
    await _waitFor(() => started.contains('blocker'));

    final jobs = <DownloadJob>[
      DownloadJob(
        track: _track('background', 100),
        opener: _opener(_bytes(100), onOpen: (_) => started.add('background')),
        generation: generations.current,
        priority: DownloadPriority.background,
      ),
      DownloadJob(
        track: _track('next', 100),
        opener: _opener(_bytes(100), onOpen: (_) => started.add('next')),
        generation: generations.current,
        priority: DownloadPriority.next,
      ),
      DownloadJob(
        track: _track('foreground', 100),
        opener: _opener(_bytes(100), onOpen: (_) => started.add('foreground')),
        generation: generations.current,
        priority: DownloadPriority.foreground,
      ),
    ];
    final futures = jobs.map(downloads.schedule).toList();
    release.complete();
    await Future.wait<DownloadOutcome>([blockerDone, ...futures]);
    expect(started, ['blocker', 'foreground', 'next', 'background']);
  });

  test('runs no more than the configured concurrency', () async {
    downloads = DownloadManager(
      cache: cache,
      streams: streams,
      generations: generations,
      maxConcurrent: 2,
    );
    final release = Completer<void>();
    var opened = 0;
    Future<StreamResponse> blocked(int start, int? end) async {
      opened++;
      await release.future;
      return StreamResponse(
        statusCode: 200,
        headers: const {'content-length': '20'},
        totalSize: 20,
        bytes: Stream.value(_bytes(20)),
        close: () async {},
      );
    }

    final futures = [
      downloads.schedule(
        DownloadJob(
          track: _track('one', 20),
          opener: blocked,
          generation: generations.current,
          priority: DownloadPriority.next,
        ),
      ),
      downloads.schedule(
        DownloadJob(
          track: _track('two', 20),
          opener: blocked,
          generation: generations.current,
          priority: DownloadPriority.next,
        ),
      ),
      downloads.schedule(
        DownloadJob(
          track: _track('three', 20),
          opener: blocked,
          generation: generations.current,
          priority: DownloadPriority.next,
        ),
      ),
    ];
    await _waitFor(() => opened == 2);
    expect(downloads.activeDownloads, 2);
    release.complete();
    final outcomes = await Future.wait(futures);
    expect(outcomes.every((outcome) => outcome.completed), isTrue);
    expect(opened, 3);
  });

  test(
    'cancelling a prefetch keeps partial bytes for the next attempt',
    () async {
      final data = _bytes(4096);
      final slow = DownloadJob(
        track: _track('resume', data.length),
        opener: _opener(data, delay: const Duration(milliseconds: 2)),
        generation: generations.current,
        priority: DownloadPriority.next,
      );
      final slowDone = downloads.schedule(slow);
      await _waitFor(() => slow.bytes > 0);
      downloads.cancelPrefetches();
      final cancelled = await slowDone;
      expect(cancelled.succeeded, isFalse);
      expect(cancelled.failure?.kind, StreamFailureKind.cancelled);

      final resumed = await downloads.schedule(
        DownloadJob(
          track: _track('resume', data.length),
          opener: _opener(data),
          generation: generations.current,
          priority: DownloadPriority.next,
        ),
      );
      expect(resumed.completed, isTrue);
      expect(resumed.verified, isTrue);
      final entry = await cache.open(_track('resume', data.length));
      expect(entry, isNotNull);
      expect(entry!.isComplete, isTrue);
      expect(await entry.read(0, data.length), data);
    },
  );

  test('a fully cached track is not downloaded again', () async {
    final data = _bytes(512);
    final track = _track('cached', data.length);
    final entry = await cache.create(track);
    await entry.write(0, data);
    expect(await entry.finish(), isTrue);
    var opened = false;
    final outcome = await downloads.schedule(
      DownloadJob(
        track: track,
        opener: (start, end) async {
          opened = true;
          throw StateError('should not download');
        },
        generation: generations.current,
        priority: DownloadPriority.next,
      ),
    );
    expect(outcome.cached, isTrue);
    expect(opened, isFalse);
  });

  test('pausing prefetch opens no connection until resumed', () async {
    downloads.pausePrefetch();
    var calls = 0;
    final finished = downloads.schedule(
      DownloadJob(
        track: _track('paused', 256),
        opener: _opener(_bytes(256), onOpen: (_) => calls++),
        generation: generations.current,
        priority: DownloadPriority.next,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(calls, 0);
    downloads.resumePrefetch();
    final outcome = await finished;
    expect(outcome.completed, isTrue);
    expect(calls, 1);
  });
}
