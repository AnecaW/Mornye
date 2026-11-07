import 'dart:async';
import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/native_iphone/native_iphone_runtime.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart' as playback;
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/services/media_library_browser.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playable_media.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(defaultService: 'existing-provider');
}

class _Downloads extends DownloadQueueNotifier {
  final added = <Track>[];
  String? service;
  @override
  DownloadQueueState build() => const DownloadQueueState();
  @override
  void addIndividualTracksToQueue(List<Track> tracks, String service) {
    added.addAll(tracks);
    this.service = service;
  }
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
  @override
  Future<void> ensureInitialized() async {}
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _CurrentMedia extends CurrentMediaItemNotifier {
  @override
  Stream<audio.MediaItem?> build() => Stream.value(null);
}

const _songs = [
  PlayableMedia(id: 'one', source: '/one.flac', title: 'One', artist: 'Artist'),
  PlayableMedia(id: 'two', source: '/two.flac', title: 'Two', artist: 'Artist'),
];

class _Browser implements MediaLibraryBrowser {
  Future<List<PlayableMedia>> Function()? fetch;
  @override
  Future<List<PlayableMedia>> librarySongs() async =>
      fetch == null ? _songs : await fetch!();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Runtime implements MusicPlayerRuntime {
  _Runtime(this.browser);
  @override
  final MediaLibraryBrowser browser;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements MusicPlayerController {
  Duration? seekPosition;
  @override
  Future<void> seek(Duration position) async => seekPosition = position;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback extends playback.PlaybackController {
  List<PlayableMedia>? queue;
  int? index;
  String? externalPath;
  @override
  playback.PlaybackState build() => const playback.PlaybackState();
  @override
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
  }) async {
    this.queue = queue.toList();
    index = startIndex;
    this.externalPath = externalPath;
  }
}

class _Search extends TrackNotifier {
  String? query;
  String? filter;
  @override
  TrackState build() => const TrackState();
  @override
  Future<void> search(String query, {String? filterOverride}) async {
    this.query = query;
    filter = filterOverride;
    state = const TrackState(
      tracks: [
        Track(
          id: 'catalog',
          name: 'Found song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 245000,
        ),
      ],
    );
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = 'com.zarz.mornye/native_iphone';
  const codec = StandardMethodCodec();
  late _Player player;
  late _Playback playbackController;
  late _Downloads downloads;
  late _Search search;
  late _Browser browser;
  final snapshots = <Map<Object?, Object?>>[];

  Future<Object?> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final reply = Completer<ByteData?>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel,
      codec.encodeMethodCall(MethodCall(method, args)),
      reply.complete,
    );
    return codec.decodeEnvelope((await reply.future)!);
  }

  Future<void> mount(WidgetTester tester) async {
    player = _Player();
    playbackController = _Playback();
    downloads = _Downloads();
    search = _Search();
    browser = _Browser();
    snapshots.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(channel),
      (call) async {
        if (call.method == 'state') {
          snapshots.add(Map<Object?, Object?>.from(call.arguments as Map));
        }
        return null;
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadQueueProvider.overrideWith(() => downloads),
          extensionProvider.overrideWith(_Extensions.new),
          localLibraryProvider.overrideWith(_Library.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          currentMediaItemProvider.overrideWith(_CurrentMedia.new),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(audio.PlaybackState()),
          ),
          playQueueProvider.overrideWith((ref) => Stream.value(const [])),
          musicPlayerRuntimeProvider.overrideWithValue(_Runtime(browser)),
          musicPlayerControllerProvider.overrideWithValue(player),
          playback.playbackProvider.overrideWith(() => playbackController),
          trackProvider.overrideWith(() => search),
        ],
        child: const NativeIPhoneRuntime(),
      ),
    );
    await tester.pump();
  }

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(channel),
      null,
    );
  });

  testWidgets(
    'native collection selection keeps queue order and external player routing',
    (tester) async {
      await mount(tester);
      final library = await command('library') as List;
      expect(library.map((row) => (row as Map)['id']), ['one', 'two']);
      await command('playAll', {
        'ids': ['two', 'one'],
        'index': 1,
      });
      expect(playbackController.queue?.map((song) => song.id), ['two', 'one']);
      expect(playbackController.index, 1);
      expect(playbackController.externalPath, '/one.flac');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native seek is forwarded in milliseconds to the existing player',
    (tester) async {
      await mount(tester);
      await command('seek', {'position': 12500});
      expect(player.seekPosition, const Duration(milliseconds: 12500));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native search and download use the existing controllers and provider choice',
    (tester) async {
      await mount(tester);
      final results = await command('search', {'query': '  a song  '}) as List;
      expect(search.query, 'a song');
      expect(search.filter, 'track');
      expect((results.single as Map)['duration'], 245);
      await command('download', {'id': 'catalog'});
      expect(downloads.added.single.id, 'catalog');
      expect(downloads.service, 'existing-provider');
      expect(
        snapshots.last['settings'],
        containsPair('defaultService', 'existing-provider'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a stale native song cannot start another song', (tester) async {
    await mount(tester);
    await expectLater(
      command('play', {'id': 'removed'}),
      throwsA(isA<PlatformException>()),
    );
    await command('library');
    await expectLater(
      command('playAll', {
        'ids': ['one', 'removed', 'two'],
        'index': 1,
      }),
      throwsA(isA<PlatformException>()),
    );
    expect(playbackController.queue, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a late library response cannot replace the latest playable selection',
    (tester) async {
      await mount(tester);
      final first = Completer<List<PlayableMedia>>();
      final second = Completer<List<PlayableMedia>>();
      var requests = 0;
      browser.fetch = () => requests++ == 0 ? first.future : second.future;
      final oldResponse = command('library');
      await tester.pump();
      final newResponse = command('library');
      await tester.pump();
      const latest = PlayableMedia(
        id: 'latest',
        source: '/latest.flac',
        title: 'Latest',
        artist: 'Artist',
      );
      second.complete([latest]);
      await newResponse;
      first.complete(_songs);
      expect(await oldResponse, isEmpty);
      await command('playAll', {
        'ids': ['latest'],
        'index': 0,
      });
      expect(playbackController.externalPath, '/latest.flac');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
