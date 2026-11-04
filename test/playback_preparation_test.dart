import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_preparation.dart';
import 'package:mornye/services/server_scrobbling.dart';

void main() {
  test('temporary preparation errors recover with bounded attempts', () async {
    var attempts = 0, recoveries = 0;
    final result = await prepareNetworkPlayback<String>(
      prepare: (_) async {
        if (++attempts < 3) throw const SocketException('temporary');
        return 'ready';
      },
      current: () => true,
      recovering: (_) async {
        recoveries++;
      },
      wait: (_) async {},
    );
    expect(result, 'ready');
    expect(attempts, 3);
    expect(recoveries, 2);
  });
  test('permanent authentication errors are never retried', () async {
    var attempts = 0;
    await expectLater(
      prepareNetworkPlayback<void>(
        prepare: (_) async {
          attempts++;
          throw PlatformException(code: '401', message: 'Unauthorized');
        },
        current: () => true,
        recovering: (_) async {},
        wait: (_) async {},
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(attempts, 1);
  });
  test('superseded playback never starts another attempt', () async {
    var current = true, attempts = 0;
    final result = await prepareNetworkPlayback<String>(
      prepare: (_) async {
        attempts++;
        throw const SocketException('temporary');
      },
      current: () => current,
      recovering: (_) async {
        current = false;
      },
      wait: (_) async {},
    );
    expect(result, isNull);
    expect(attempts, 1);
  });
  test('recovery stops after three failures', () async {
    var attempts = 0;
    await expectLater(
      prepareNetworkPlayback<void>(
        prepare: (_) async {
          attempts++;
          throw const SocketException('offline');
        },
        current: () => true,
        recovering: (_) async {},
        wait: (_) async {},
      ),
      throwsA(isA<SocketException>()),
    );
    expect(attempts, 3);
  });
  test(
    'listening counts forward playback once and excludes seeks/paused ticks',
    () async {
      final submissions = <String>[];
      var clock = DateTime.utc(2026, 11, 5);
      final session = ServerListeningSession(
        now: () => clock,
        submit: (source, _) async {
          submissions.add(source);
        },
      );
      session.begin('one');
      await session.tick(
        const Duration(seconds: 100),
        playing: true,
        duration: const Duration(seconds: 10),
      );
      await session.tick(
        const Duration(seconds: 101),
        playing: false,
        duration: const Duration(seconds: 10),
      );
      expect(submissions, isEmpty);
      for (var i = 102; i <= 111; i++) {
        clock = clock.add(const Duration(seconds: 1));
        await session.tick(
          Duration(seconds: i),
          playing: true,
          duration: const Duration(seconds: 10),
        );
      }
      expect(submissions, ['one']);
      session.begin('two');
      for (var i = 1; i <= 6; i++) {
        clock = clock.add(const Duration(seconds: 1));
        await session.tick(
          Duration(seconds: i),
          playing: true,
          duration: const Duration(seconds: 10),
        );
      }
      expect(submissions, ['one', 'two']);
    },
  );
}
