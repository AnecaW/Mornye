import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/stream_types.dart';

void main() {
  group('ByteRangeSet', () {
    test('merges adjacent and overlapping spans', () {
      final ranges = ByteRangeSet()
        ..add(0, 100)
        ..add(100, 50)
        ..add(200, 10);
      expect(ranges.spans, [const ByteSpan(0, 150), const ByteSpan(200, 10)]);
      expect(ranges.totalBytes, 160);
    });

    test('reports what is cached and the first missing byte', () {
      final ranges = ByteRangeSet()
        ..add(0, 100)
        ..add(150, 50);
      expect(ranges.contains(0, 100), isTrue);
      expect(ranges.contains(50, 80), isFalse);
      expect(ranges.firstMissing(0, 200), 100);
      expect(ranges.firstMissing(150, 200), isNull);
      expect(ranges.contiguousEndFrom(0), 100);
      expect(ranges.contiguousEndFrom(120), 120);
    });

    test('round-trips through JSON', () {
      final ranges = ByteRangeSet()
        ..add(0, 10)
        ..add(20, 5);
      final restored = ByteRangeSet.fromJson(ranges.toJson());
      expect(restored.spans, ranges.spans);
      expect(restored.isComplete(25), isFalse);
      restored.add(10, 10);
      expect(restored.isComplete(25), isTrue);
    });
  });

  group('HTTP ranges', () {
    test('parses the first Spotify-style chunk', () {
      final range = parseSingleByteRange('bytes=0-524287', 1000000);
      expect(range, isNotNull);
      expect(range!.start, 0);
      expect(range.end, 524288);
    });

    test('parses suffix and open-ended ranges', () {
      final suffix = parseSingleByteRange('bytes=-100', 1000)!;
      expect(suffix.start, 900);
      expect(suffix.end, 1000);
      final open = parseSingleByteRange('bytes=100-', 1000)!;
      expect(open.start, 100);
      expect(open.end, 1000);
    });

    test('rejects malformed, multi and unsatisfiable ranges', () {
      expect(parseSingleByteRange('bytes=0-1,4-5', 100), isNull);
      expect(parseSingleByteRange('items=0-1', 100), isNull);
      expect(parseSingleByteRange('bytes=100-', 100), isNull);
      expect(parseSingleByteRange('bytes=5-4', 100), isNull);
    });

    test('reads the total length from Content-Range', () {
      expect(totalSizeFromHeaders({'content-range': 'bytes 0-0/98765'}), 98765);
      expect(totalSizeFromHeaders({'content-length': '1234'}), 1234);
    });
  });

  group('StreamFailure', () {
    test('classifies transient and permanent failures', () {
      final network = StreamFailure.classify(
        const SocketException('connection reset'),
      );
      expect(network.kind, StreamFailureKind.network);
      expect(network.retryable, isTrue);

      final timeout = StreamFailure.classify(TimeoutException('slow'));
      expect(timeout.kind, StreamFailureKind.timeout);
      expect(timeout.retryable, isTrue);

      final auth = StreamFailure.classify(HttpException('Server returned 401'));
      expect(auth.kind, StreamFailureKind.authentication);
      expect(auth.retryable, isFalse);

      final missing = StreamFailure.classifyStatus(404);
      expect(missing.kind, StreamFailureKind.unavailable);
      expect(missing.retryable, isFalse);

      final server = StreamFailure.classifyStatus(503);
      expect(server.kind, StreamFailureKind.server);
      expect(server.retryable, isTrue);
    });

    test('never copies credential-bearing transport text', () {
      final failure = StreamFailure.classify(
        HttpException(
          'failed',
          uri: Uri.parse(
            'https://user:secret@nas/rest/stream?apiKey=abc&t=123',
          ),
        ),
      );
      expect(failure.toString(), isNot(contains('secret')));
      expect(failure.toString(), isNot(contains('apiKey')));
      expect(failure.detail, isNot(contains('https')));
    });

    test('has a user-facing message for every failure the player shows', () {
      for (final kind in StreamFailureKind.values) {
        final failure = StreamFailure(kind, retryable: false);
        if (kind == StreamFailureKind.cancelled) {
          expect(failure.userMessage, isEmpty);
        } else {
          expect(failure.userMessage, isNotEmpty);
          expect(failure.userMessage, isNot(contains('http')));
        }
      }
    });
  });
}
