import 'package:audio_session/audio_session.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:mornye/services/playback_load.dart';
import 'package:mornye/services/music_playback_deck.dart';
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
  testWidgets(
    'iOS HLS radio processes actual PCM through EQ and updates gain live',
    (tester) async {
      const encoded = String.fromEnvironment('TEST_HLS');
      expect(
        encoded,
        isNotEmpty,
        reason: 'The macOS job must provide actual HLS segments',
      );
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      expect(await session.setActive(true), isTrue);
      addTearDown(() => session.setActive(false));
      final requests = <String>[];
      final nativeLogs = <String>[];
      final fixtures = (jsonDecode(utf8.decode(base64Decode(encoded))) as Map)
          .cast<String, String>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(request.uri.path);
        final name = request.uri.pathSegments.lastOrNull;
        if (!fixtures.containsKey(name)) {
          request.response.statusCode = 404;
        } else {
          request.response.headers.set(
            'Content-Type',
            name!.endsWith('.m3u8')
                ? 'application/vnd.apple.mpegurl'
                : 'video/mp2t',
          );
          request.response.add(base64Decode(fixtures[name]!));
        }
        await request.response.close();
      });
      final player = AudioPlayer();
      addTearDown(player.dispose);
      final events = player.eventStream.listen((event) {
        final message = event.logMessage;
        if (message != null && message.startsWith('mornye.'))
          nativeLogs.add(message);
      });
      addTearDown(events.cancel);
      await player.getDuration();
      const channel = MethodChannel('xyz.luan/audioplayers');
      Future<void> effect(double gain) =>
          channel.invokeMethod<void>('setEqualizer', {
            'playerId': player.playerId,
            'configuration': {
              'enabled': true,
              'frequencies': [60.0, 250.0, 1000.0, 4000.0, 16000.0],
              'gains': List<double>.filled(5, 0),
              'inputGain': gain,
              'limiter': false,
            },
          });
      Future<Map<Object?, Object?>> stats() async =>
          (await channel.invokeMapMethod<Object?, Object?>(
            'getEqualizerDiagnostics',
            {'playerId': player.playerId},
          ))!;
      await player
          .setSource(UrlSource('http://127.0.0.1:${server.port}/live.m3u8'))
          .timeout(const Duration(seconds: 20));
      await effect(-12);
      await player.resume();
      var reported = false;
      Future<Map<Object?, Object?>> frames(int minimum) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {
          final sample = await stats();
          if ((sample['processedFrames'] as num) >= minimum) return sample;
          if (!reported &&
              DateTime.now().isAfter(
                end.subtract(const Duration(seconds: 8)),
              )) {
            reported = true;
            print(
              'HLS_SIGNAL_STATE state=${player.state} position=${await player.getCurrentPosition()} requests=$requests native=$nativeLogs stats=$sample',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail(
          'Decoded radio samples did not reach EQ: ${await stats()} state=${player.state} position=${await player.getCurrentPosition()} requests=$requests native=$nativeLogs',
        );
      }

      final first = await frames(22050);
      final input = (first['inputRms'] as num).toDouble();
      final output = (first['outputRms'] as num).toDouble();
      expect(input, greaterThan(0));
      expect(output / input, inInclusiveRange(0.20, 0.35));
      await effect(0);
      final second = await frames(
        (first['processedFrames'] as num).toInt() + 22050,
      );
      expect((second['outputRms'] as num).toDouble(), greaterThan(output));
      await player.pause();
    },
  );
  for (final format in ['wav', 'mp3', 'flac']) {
    testWidgets('native Subsonic $format EQ streaming, seeking and offline cache', (
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
      final streamingCache = NetworkAudioCache(
        directory: () async => directory,
      );
      await streamingCache.initialize();
      streamingCache.wifiOnly = false;
      final storage = NetworkStorageService(
        audioCache: streamingCache,
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
      // Reproduce direct cold FLAC selection while prefetch has only a
      // header. AVPlayer must stream now, without waiting for this producer.
      final releaseFill = Completer<void>();
      Future<void>? backgroundFill;
      if (format == 'flac') {
        final started = Completer<void>();
        final path = SubsonicSong(server.song).path;
        final key =
            '${jsonEncode((await storage.connection('fixture')).toJson())}/$path';
        backgroundFill = streamingCache.fetch(key, format, (file, _) async {
          await file.writeAsBytes(bytes.take(4).toList());
          streamingCache.reportLength(key, bytes.length);
          started.complete();
          await releaseFill.future;
          await file.writeAsBytes(bytes);
        });
        await started.future;
        addTearDown(() async {
          if (!releaseFill.isCompleted) releaseFill.complete();
          await backgroundFill;
        });
        expect(await streamingCache.lookup(key, format), isNull);
      }
      final player = AudioPlayer();
      addTearDown(player.dispose);
      await player.setVolume(1);
      final preparation = PlaybackLoad();
      final url = await storage.preparePlayback(source, preparation);
      await player.getDuration();
      await const MethodChannel(
        'xyz.luan/audioplayers',
      ).invokeMethod<void>('setBufferingPolicy', {
        'playerId': player.playerId,
        'configuration': preparation.bufferPolicy.toNative(),
      });
      expect(Uri.parse(url).query, isEmpty);
      await player
          .setSource(UrlSource(url))
          .timeout(const Duration(seconds: 20));
      expect((await player.getDuration())!.inMilliseconds, greaterThan(1500));
      // Validate the same uncached source with EQ off before exercising
      // the already working concrete-track EQ path below.
      await player.resume();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        (await player.getCurrentPosition())!.inMilliseconds,
        greaterThan(0),
      );
      await player.pause();
      if (format == 'flac') expect(releaseFill.isCompleted, isFalse);
      const effects = MethodChannel('xyz.luan/audioplayers');
      await effects.invokeMethod<void>('setEqualizer', {
        'playerId': player.playerId,
        'configuration': {
          'enabled': true,
          'frequencies': [60.0, 250.0, 1000.0, 4000.0, 16000.0],
          'gains': List<double>.filled(5, 0),
          'inputGain': -6.0,
          'limiter': false,
        },
      });
      await player.resume();
      final eqDeadline = DateTime.now().add(const Duration(seconds: 10));
      Map<Object?, Object?> eq = const {};
      do {
        eq = (await effects.invokeMapMethod<Object?, Object?>(
          'getEqualizerDiagnostics',
          {'playerId': player.playerId},
        ))!;
        if ((eq['processedFrames'] as num) >= 4410) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } while (DateTime.now().isBefore(eqDeadline));
      expect(
        eq['processedFrames'],
        greaterThanOrEqualTo(4410),
        reason: '$format NAS samples must actually pass through EQ: $eq',
      );
      expect((eq['inputRms'] as num).toDouble(), greaterThan(0));
      expect(
        (eq['outputRms'] as num) / (eq['inputRms'] as num),
        inInclusiveRange(0.45, 0.55),
        reason: '$format must apply the -6 dB gain',
      );
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

      if (backgroundFill != null) {
        expect(releaseFill.isCompleted, isFalse);
        releaseFill.complete();
        await backgroundFill;
      }
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
  testWidgets(
    'native AVPlayer cancels a blocked NAS load and survives 20 source changes',
    (tester) async {
      final server = await SubsonicFixture.start();
      addTearDown(server.close);
      server.audio = _wave();
      server.song['suffix'] = 'wav';
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
      final deck = AudioplayersPlaybackDeck(
        playerId: 'native-cancellation-stress',
        nativeAvailable: false,
        equalizerAvailable: false,
      );
      addTearDown(deck.dispose);
      await deck.configureOutput();
      await deck.setVolume(0);
      server.blockMethod = 'stream';
      final initial = deck.setNetworkSource(
        await storage.resolve(source, forPlayback: true),
      );
      await server.held.future.timeout(const Duration(seconds: 10));
      await deck.cancelPreparation().timeout(const Duration(seconds: 2));
      await initial.timeout(const Duration(seconds: 2));
      server.blockMethod = null;
      server.release.complete();
      for (var i = 0; i < 20; i++) {
        final preparing = deck.setNetworkSource(
          await storage.resolve(source, forPlayback: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await deck.cancelPreparation();
        await preparing.timeout(const Duration(seconds: 2));
      }
      await deck.setNetworkSource(
        await storage.preparePlayback(source, PlaybackLoad()),
      );
      await deck.resume();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect((await deck.getCurrentPosition())!.inMilliseconds, greaterThan(0));
      await deck.pause();
    },
  );
}
