import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/playback_generation.dart';
import 'package:mornye/services/streaming/stream_diagnostics.dart';
import 'package:mornye/services/streaming/stream_manager.dart';
import 'package:mornye/services/streaming/stream_types.dart';

StreamResponse _ok() => StreamResponse(
  statusCode: 200,
  headers: const {'content-length': '3'},
  bytes: Stream.value(const [1, 2, 3]),
);

void main() {
  late GenerationManager generations;
  late StreamDiagnostics diagnostics;
  late StreamManager manager;

  setUp(() {
    generations = GenerationManager();
    diagnostics = StreamDiagnostics();
    manager = StreamManager(
      diagnostics: diagnostics,
      initialBackoff: const Duration(milliseconds: 5),
      maxBackoff: const Duration(milliseconds: 20),
    );
  });

  test(
    'retries transient failures and returns the eventual response',
    () async {
      var attempts = 0;
      final response = await manager.open(
        generation: generations.current,
        generations: generations,
        opener: (start, end) async {
          attempts++;
          if (attempts < 3) throw const SocketException('reset');
          return _ok();
        },
      );
      expect(response.statusCode, 200);
      expect(attempts, 3);
      expect(diagnostics.totalRetries, 2);
      expect(manager.health.failureRate, greaterThan(0));
    },
  );

  test('does not retry a permanent missing track', () async {
    var attempts = 0;
    await expectLater(
      manager.open(
        generation: generations.current,
        generations: generations,
        opener: (start, end) async {
          attempts++;
          throw HttpException('Server returned 404');
        },
      ),
      throwsA(
        isA<StreamFailure>().having(
          (failure) => failure.kind,
          'kind',
          StreamFailureKind.unavailable,
        ),
      ),
    );
    expect(attempts, 1);
    expect(diagnostics.totalRetries, 0);
  });

  test(
    'refreshes authentication once, then reports the auth failure',
    () async {
      var refreshed = 0;
      manager = StreamManager(
        diagnostics: diagnostics,
        initialBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 10),
        onAuthenticationFailure: () async => refreshed++,
      );
      var attempts = 0;
      await expectLater(
        manager.open(
          generation: generations.current,
          generations: generations,
          opener: (start, end) async {
            attempts++;
            throw HttpException('Server returned 401');
          },
        ),
        throwsA(
          isA<StreamFailure>().having(
            (failure) => failure.kind,
            'kind',
            StreamFailureKind.authentication,
          ),
        ),
      );
      expect(refreshed, 1);
      expect(attempts, 2);
    },
  );

  test('a superseded generation cancels the retry wait', () async {
    manager = StreamManager(
      diagnostics: diagnostics,
      initialBackoff: const Duration(milliseconds: 400),
      maxBackoff: const Duration(milliseconds: 400),
    );
    final generation = generations.advance('track');
    var attempts = 0;
    final future = manager.open(
      generation: generation,
      generations: generations,
      opener: (start, end) async {
        attempts++;
        throw const SocketException('offline');
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    generations.advance('next');
    await expectLater(
      future,
      throwsA(
        isA<StreamFailure>().having(
          (failure) => failure.kind,
          'kind',
          StreamFailureKind.cancelled,
        ),
      ),
    );
    expect(attempts, 1);
    expect(manager.activeRequests, 0);
  });

  test('refuses to start for an already superseded generation', () async {
    final generation = generations.advance('old');
    generations.advance('new');
    await expectLater(
      manager.open(
        generation: generation,
        generations: generations,
        opener: (start, end) async => _ok(),
      ),
      throwsA(isA<StreamFailure>()),
    );
  });
}
