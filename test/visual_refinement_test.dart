import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:mornye/services/library_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_scan_activity.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/library_scan_status.dart';
import 'package:mornye/widgets/live_broadcast_controls.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';
import 'package:mornye/widgets/player_playback_controls.dart';

class _Player extends MusicPlayerController {
  final calls = <bool>[];
  @override
  Future<void> togglePlayPause(bool playing) async => calls.add(playing);
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState(
    sources: [
      LocalLibrarySource(
        id: 'nas',
        path: 'network://nas/',
        displayName: 'Navidrome',
        enabled: true,
        available: true,
      ),
    ],
    isScanning: true,
    scanningSourceId: 'nas',
    scannedFiles: 50,
    scanTotalFiles: 100,
    scanActivity: const LibraryScanActivity(
      phase: 'metadata',
      processed: 50,
      total: 100,
      albums: 8,
      artists: 4,
      elapsed: Duration(seconds: 10),
    ),
  );
  void unknown() => state = state.copyWith(
    scanActivity: const LibraryScanActivity(phase: 'connecting'),
    scanTotalFiles: 0,
  );
  void finish() => state = state.copyWith(isScanning: false, scanProgress: 100);
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('VISUAL_PREVIEWS')) return;
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final directory = Directory('.tmp/visual-polish-previews');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

Widget shell(
  Widget child,
  ThemeData theme, {
  double scale = 1,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('nl'),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: RepaintBoundary(key: const ValueKey('preview'), child: child!),
    ),
    home: RepaintBoundary(
      key: const ValueKey('body-preview'),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);
void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('VISUAL_PREVIEWS')) return;
    for (final font in <String, String>{
      'Inter': 'assets/fonts/InterVariable.ttf',
      'Google Sans Flex': 'assets/fonts/GoogleSansFlex.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/material_symbols_icons/MaterialSymbolsRounded':
          'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  test(
    'only explicit radio identities are live; zero duration is insufficient',
    () {
      expect(isLiveBroadcastId('subsonic-radio://nas/station'), isTrue);
      for (final id in [
        null,
        '/song.flac',
        'network://nas/song',
        'song',
        'https://radio.example/song.mp3',
      ]) {
        expect(isLiveBroadcastId(id), isFalse);
      }
    },
  );
  for (final mornye in [true, false]) {
    for (final dark in [true, false]) {
      final theme = mornye
          ? MornyeTheme.build(dark ? Brightness.dark : Brightness.light)
          : dark
          ? AppTheme.dark()
          : AppTheme.light();
      for (final width in [320.0, 768.0, 1280.0]) {
        for (final scale in [1.0, 1.6]) {
          testWidgets(
            'live controls fit $width / $scale / Mornye $mornye / dark $dark',
            (tester) async {
              tester.view.physicalSize = Size(width, 640);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              final player = _Player();
              final metadata = PlayerMetadataController();
              addTearDown(metadata.dispose);
              final seek = PlaybackSeekPreview();
              addTearDown(seek.dispose);
              await tester.pumpWidget(
                shell(
                  SizedBox(
                    width: 560,
                    child: PlayerPlaybackControls(
                      mediaId: 'subsonic-radio://nas/station',
                      duration: Duration.zero,
                      seekPreview: seek,
                      colorScheme: theme.colorScheme,
                      metadata: metadata,
                    ),
                  ),
                  theme,
                  scale: scale,
                  overrides: [
                    musicPlayerControllerProvider.overrideWithValue(player),
                    playbackPlayingProvider.overrideWith((ref) => true),
                    playbackLoadingProvider.overrideWith((ref) => false),
                  ],
                ),
              );
              await tester.pump(const Duration(milliseconds: 250));
              expect(find.byType(PlaybackSeekSlider), findsNothing);
              expect(find.byType(Slider), findsNothing);
              expect(find.text('LIVE'), findsOneWidget);
              final l = AppLocalizations.of(tester.element(find.text('LIVE')));
              expect(find.byTooltip(l.nowPlayingPreviousTrack), findsNothing);
              expect(find.byTooltip(l.nowPlayingNextTrack), findsNothing);
              await tester.tap(find.byTooltip(l.actionPause));
              expect(player.calls, [true]);
              expect(tester.takeException(), isNull);
              if (scale == 1 && width == 320)
                await capture(
                  tester,
                  'live-${mornye ? 'mornye' : 'material'}-${dark ? 'dark' : 'light'}',
                );
              await tester.pumpWidget(const SizedBox.shrink());
            },
          );
        }
      }
      testWidgets(
        'shared scan popup fits $mornye / $dark, switches unknown totals and stops on completion',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final c = ProviderContainer(
            overrides: [localLibraryProvider.overrideWith(_Library.new)],
          );
          addTearDown(c.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: MaterialApp(
                theme: theme,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => RepaintBoundary(
                  key: const ValueKey('preview'),
                  child: child!,
                ),
                home: RepaintBoundary(
                  key: const ValueKey('body-preview'),
                  child: Scaffold(
                    body: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showLibraryScanDialog(context),
                        child: const Text('Open scan'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open scan'));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(find.textContaining('50 / 100'), findsOneWidget);
          expect(find.textContaining('≈ 10s'), findsOneWidget);
          expect(find.byType(LibraryScanProgress), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture(
            tester,
            'scan-${mornye ? 'mornye' : 'material'}-${dark ? 'dark' : 'light'}',
          );
          (c.read(localLibraryProvider.notifier) as _Library).unknown();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.textContaining('50%'), findsNothing);
          expect(find.byType(AppProgressIndicator), findsOneWidget);
          (c.read(localLibraryProvider.notifier) as _Library).finish();
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(find.byType(AppProgressIndicator), findsNothing);
          expect(tester.binding.hasScheduledFrame, isFalse);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  testWidgets('live status and loading obey reduced motion and hidden tabs', (
    tester,
  ) async {
    var playing = true, loading = false, reduced = false, visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: TickerMode(
                enabled: visible,
                child: Column(
                  children: [
                    LiveBroadcastTimeline(playing: playing, loading: loading),
                    const AppLoadingIndicator(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
    update(() => reduced = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    update(() {
      reduced = false;
      visible = false;
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    update(() {
      visible = true;
      loading = true;
    });
    await tester.pump();
    expect(find.text('Connecting…'), findsOneWidget);
    update(() {
      loading = false;
      playing = false;
    });
    await tester.pump();
    expect(find.text('Paused'), findsOneWidget);
    expect(find.byType(M3ELoadingIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
