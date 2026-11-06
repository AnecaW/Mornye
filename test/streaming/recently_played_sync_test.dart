import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/recently_played_sync.dart';

void main() {
  late List<({String source, String songId, bool submission, int? time})> sent;
  late int failures;

  RecentlyPlayedSync createSync({int maxAttempts = 3}) {
    sent = [];
    failures = 0;
    return RecentlyPlayedSync(
      send: (source, songId, {required submission, timeMs}) async {
        if (failures > 0) {
          failures--;
          throw StateError('server offline');
        }
        sent.add((
          source: source,
          songId: songId,
          submission: submission,
          time: timeMs,
        ));
      },
      maxAttempts: maxAttempts,
      initialRetry: const Duration(milliseconds: 5),
      maxRetry: const Duration(milliseconds: 10),
    );
  }

  test(
    'announces now playing, then records one play after 30 seconds',
    () async {
      final sync = createSync();
      sync.update(
        source: 'network://nas/song/1',
        songId: '1',
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 4),
        playing: true,
        ended: false,
      );
      await sync.flush();
      expect(sent, hasLength(1));
      expect(sent.single.submission, isFalse);
      expect(sent.single.time, isNull);

      sync.update(
        source: 'network://nas/song/1',
        songId: '1',
        position: const Duration(seconds: 31),
        duration: const Duration(minutes: 4),
        playing: true,
        ended: false,
      );
      await sync.flush();
      expect(sent, hasLength(2));
      expect(sent.last.submission, isTrue);
      expect(sent.last.time, isNotNull);

      sync.update(
        source: 'network://nas/song/1',
        songId: '1',
        position: const Duration(seconds: 60),
        duration: const Duration(minutes: 4),
        playing: true,
        ended: false,
      );
      await sync.flush();
      expect(sent, hasLength(2));
    },
  );

  test('never records a track that was selected but never started', () async {
    final sync = createSync();
    sync.update(
      source: 'network://nas/song/1',
      songId: '1',
      position: Duration.zero,
      playing: false,
      ended: false,
    );
    await sync.flush();
    expect(sent, isEmpty);
  });

  test('qualifies at half of a short track', () async {
    final sync = createSync();
    sync.update(
      source: 'network://nas/song/2',
      songId: '2',
      position: const Duration(seconds: 10),
      duration: const Duration(seconds: 20),
      playing: true,
      ended: false,
    );
    await sync.flush();
    expect(sent.where((entry) => entry.submission), hasLength(1));
  });

  test('retries a temporary server failure', () async {
    final sync = createSync();
    failures = 1;
    sync.update(
      source: 'network://nas/song/3',
      songId: '3',
      position: const Duration(seconds: 40),
      duration: const Duration(minutes: 3),
      playing: true,
      ended: false,
    );
    await sync.flush();
    expect(sent, isEmpty);
    expect(sync.pendingCount, 2);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sync.pendingCount, 0);
    expect(sent, hasLength(2));
    expect(sent.last.submission, isTrue);
  });

  test(
    'drops an item after the attempt limit instead of retrying forever',
    () async {
      final sync = createSync(maxAttempts: 2);
      failures = 10;
      sync.update(
        source: 'network://nas/song/4',
        songId: '4',
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 3),
        playing: true,
        ended: false,
      );
      await sync.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sync.pendingCount, 0);
      expect(sent, isEmpty);
    },
  );

  test('a new track gets a fresh history entry', () async {
    final sync = createSync();
    sync.update(
      source: 'network://nas/song/5',
      songId: '5',
      position: const Duration(seconds: 40),
      duration: const Duration(minutes: 3),
      playing: true,
      ended: false,
    );
    await sync.flush();
    sync.update(
      source: 'network://nas/song/6',
      songId: '6',
      position: const Duration(seconds: 40),
      duration: const Duration(minutes: 3),
      playing: true,
      ended: false,
    );
    await sync.flush();
    expect(sent.where((entry) => entry.submission), hasLength(2));
    expect(sent.map((entry) => entry.songId).toSet(), {'5', '6'});
  });
}
