import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/live_broadcast_controls.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/radio_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final width in [320.0, 768.0, 1280.0]) {
    for (final compact in [true, false]) {
      testWidgets('LIVE group is centered at $width pixels, compact=$compact', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: LiveBroadcastTimeline(
                  playing: false,
                  loading: false,
                  compact: compact,
                ),
              ),
            ),
          ),
        );
        final status = find.byKey(const ValueKey('live-broadcast-status'));
        expect(tester.getCenter(status).dx, closeTo(width / 2, 0.01));
        expect(tester.takeException(), isNull);
      });
    }
  }
  test('ICY uses actual artist/title and preserves Unicode and semicolons', () {
    final fields = parseIcyMetadata(
      utf8.encode(
        "StreamTitle='Björk - Jóga; Live';StreamUrl='https://station.test';\u0000",
      ),
    );
    final track = RadioTrackMetadata.fromFields(fields);
    expect(track.artist, 'Björk');
    expect(track.title, 'Jóga; Live');
    expect(track.album, isEmpty);
    expect(
      RadioTrackMetadata.fromFields({'streamTitle': 'News'}).artist,
      isEmpty,
    );
    expect(RadioTrackMetadata.fromFields({'streamTitle': ''}).title, isEmpty);
    expect(
      parseIcyMetadata(utf8.encode("StreamUrl='https://station.test';")),
      isEmpty,
    );
  });
  test(
    'ICY parser reads across arbitrary byte chunks without retaining audio',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.headers.value('icy-metadata'), '1');
        request.response.headers.set('icy-metaint', '3');
        final bytes = utf8.encode("StreamTitle='Artist - Song';");
        final padded = [
          ...bytes,
          ...List.filled((16 - bytes.length % 16) % 16, 0),
        ];
        for (final byte in [1, 2, 3, padded.length ~/ 16, ...padded]) {
          request.response.add([byte]);
          await request.response.flush();
        }
        await request.response.close();
      });
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final result = await readIcyMetadata(
        client,
        Uri.parse('http://127.0.0.1:${server.port}/radio'),
      );
      expect(result, {'streamTitle': 'Artist - Song'});
    },
  );
  test(
    'non-ICY and HTTP failures never become fabricated track titles',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 401;
        request.response.write('<html>Authentication failed</html>');
        await request.response.close();
      });
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      expect(
        await readIcyMetadata(
          client,
          Uri.parse('http://127.0.0.1:${server.port}/'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'late native callback cannot replace a newer station after cancellation',
    () async {
      final pending = Completer<Map<String, String>>();
      final changes = <RadioTrackMetadata>[];
      final monitor = RadioMetadataMonitor(
        source: 'https://station.test/radio',
        native: () => pending.future,
        onChanged: changes.add,
      )..start();
      monitor.close();
      pending.complete({
        'source': 'https://station.test/radio',
        'title': 'Old song',
      });
      await Future<void>.delayed(Duration.zero);
      expect(changes, isEmpty);
    },
  );
}
