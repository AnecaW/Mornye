import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/network_audio_cache.dart';
import 'package:mornye/services/network_storage_service.dart';

import '../test/support/subsonic_fixture.dart';

Uint8List _wave() {
  const rate = 44100, frames = rate * 2;
  final data = ByteData(44 + frames * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    data.setInt16(
      44 + i * 2,
      (2000 * sin(i * 2 * pi * 440 / rate)).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const fixtures = {
    'mp3': String.fromEnvironment('TEST_MP3'),
    'flac': String.fromEnvironment('TEST_FLAC'),
  };
  for (final format in ['wav', 'mp3', 'flac']) {
    testWidgets('native Subsonic $format streaming, seeking and offline cache', (
      tester,
    ) async {
      final bytes = format == 'wav' ? _wave() : base64Decode(fixtures[format]!);
      expect(
        bytes,
        isNotEmpty,
        reason:
            'Provide the generated $format fixture through TEST_${format.toUpperCase()}',
      );
      final directory = await Directory.systemTemp.createTemp(
        'subsonic-native-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await SubsonicFixture.start();
      addTearDown(server.close);
      server.audio = bytes;
      server.ignoreRanges = true;
      server.audioContentType = 'application/octet-stream';
      server.song['id'] = 'native-$format /?&';
      server.song['suffix'] = format;
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(server.connection());
      final source = NetworkStorageService.source(
        'fixture',
        SubsonicSong(server.song).path,
      );
      final player = AudioPlayer();
      addTearDown(player.dispose);
      await player.setVolume(0);
      final url = await storage.resolve(source);
      expect(Uri.parse(url).query, isEmpty);
      await player
          .setSource(UrlSource(url))
          .timeout(const Duration(seconds: 20));
      expect((await player.getDuration())!.inMilliseconds, greaterThan(1500));
      await player.resume();
      await player.seek(const Duration(milliseconds: 700));
      await player.pause();
      expect(
        (await player.getCurrentPosition())!.inMilliseconds,
        closeTo(700, 250),
      );
      await player.release();
      expect(server.ranges.whereType<String>(), isNotEmpty);
      expect(
        server.requests
            .where((r) => r.path.endsWith('/stream.view'))
            .every(
              (r) =>
                  r.queryParameters['u'] == 'listener' &&
                  r.queryParameters['s']!.isNotEmpty &&
                  r.queryParameters['t']!.isNotEmpty,
            ),
        isTrue,
      );

      final cache = NetworkAudioCache(directory: () async => directory);
      await cache.initialize();
      cache.wifiOnly = false;
      final cachedStorage = NetworkStorageService(
        audioCache: cache,
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      addTearDown(cachedStorage.dispose);
      await cachedStorage.save(server.connection());
      await cachedStorage.cacheAudio(source, manual: true);
      server.disconnect = true;
      cachedStorage.setReachable('fixture', reachable: false);
      final local = await cachedStorage.resolve(source);
      expect(File(local).isAbsolute, isTrue);
      await player
          .setSource(DeviceFileSource(local))
          .timeout(const Duration(seconds: 20));
      await player.resume();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        (await player.getCurrentPosition())!.inMilliseconds,
        greaterThan(0),
      );
      await player.pause();
    });
  }
}
