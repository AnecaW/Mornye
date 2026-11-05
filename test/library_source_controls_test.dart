import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/library_scan_activity.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/library_source_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/widgets/library_source_selector.dart';
import 'package:mornye/widgets/library_server_radio.dart';
import 'package:mornye/widgets/library_scan_status.dart';
import 'support/subsonic_fixture.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(localLibraryEnabled: true);
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState(
    sources: [
      LocalLibrarySource(
        id: 'root',
        path: 'network://fixture/',
        displayName: 'Music server',
        enabled: true,
        available: true,
      ),
    ],
  );
  void disable(bool disabled) => state = state.copyWith(
    sources: [state.sources.single.copyWith(enabled: !disabled)],
  );
  void progress(LibraryScanActivity a) => state = state.copyWith(
    isScanning: true,
    scanningSourceId: 'root',
    scanActivity: a,
    scannedFiles: a.processed,
    scanTotalFiles: a.total ?? 0,
  );
}

Widget app(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'phase ETA uses actual throughput and refuses unknown or insufficient totals',
    () {
      expect(
        const LibraryScanActivity(
          phase: 'metadata',
          processed: 50,
          elapsed: Duration(seconds: 10),
        ).remaining,
        isNull,
      );
      expect(
        const LibraryScanActivity(
          phase: 'metadata',
          processed: 2,
          total: 100,
          elapsed: Duration(seconds: 10),
        ).remaining,
        isNull,
      );
      const a = LibraryScanActivity(
        phase: 'metadata',
        processed: 50,
        total: 100,
        elapsed: Duration(seconds: 10),
      );
      expect(a.fraction, .5);
      expect(a.remaining, const Duration(seconds: 10));
    },
  );
  test(
    'disabled saved server disappears without removing its connection or cached sources',
    () async {
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(
        const NetworkConnection(
          id: 'fixture',
          name: 'Music server',
          protocol: NetworkProtocol.subsonic,
          address: 'https://music.test',
        ),
      );
      final c = ProviderContainer(
        overrides: [
          librarySourceStorageProvider.overrideWithValue(storage),
          localLibraryProvider.overrideWith(_Library.new),
          settingsProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(c.dispose);
      expect(
        await c.read(librarySourceConnectionsProvider.future),
        hasLength(1),
      );
      await c
          .read(selectedLibrarySourceProvider.notifier)
          .select(serverMusicSource('fixture'));
      c.read(localLibraryProvider.notifier) as _Library;
      (c.read(localLibraryProvider.notifier) as _Library).disable(true);
      expect(await c.read(librarySourceConnectionsProvider.future), isEmpty);
      expect(c.read(effectiveLibrarySourceProvider), allMusicSources);
      expect(await storage.connections(), hasLength(1));
      expect(c.read(localLibraryProvider).sources, hasLength(1));
      (c.read(localLibraryProvider.notifier) as _Library).disable(false);
      expect(
        await c.read(librarySourceConnectionsProvider.future),
        hasLength(1),
      );
      expect(
        c.read(effectiveLibrarySourceProvider),
        serverMusicSource('fixture'),
      );
    },
  );
  testWidgets(
    'local switch immediately removes and restores the icon-labelled option',
    (tester) async {
      final c = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          localLibraryProvider.overrideWith(_Library.new),
          librarySourceConnectionsProvider.overrideWith((ref) async => []),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(app(c, const LibrarySourceSelector()));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.smartphone_outlined), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      c.read(settingsProvider.notifier).setLocalLibraryEnabled(false);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.smartphone_outlined), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      c.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.smartphone_outlined), findsOneWidget);
    },
  );
  testWidgets(
    'local Radio is a visible empty state rather than fabricated stations',
    (tester) async {
      final c = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          localLibraryProvider.overrideWith(_Library.new),
          librarySourceConnectionsProvider.overrideWith((ref) async => []),
        ],
      );
      addTearDown(c.dispose);
      await c
          .read(selectedLibrarySourceProvider.notifier)
          .select(deviceMusicSource);
      await tester.pumpWidget(app(c, const LibraryServerRadio()));
      await tester.pumpAndSettle();
      expect(
        find.text('No radio stations are available for this library.'),
        findsOneWidget,
      );
      expect(find.byType(ExpansionTile), findsNothing);
    },
  );
  testWidgets(
    'scan status exposes observed counts, phase percentage and phase ETA',
    (tester) async {
      final c = ProviderContainer(
        overrides: [localLibraryProvider.overrideWith(_Library.new)],
      );
      addTearDown(c.dispose);
      (c.read(localLibraryProvider.notifier) as _Library).progress(
        const LibraryScanActivity(
          phase: 'metadata',
          processed: 50,
          total: 100,
          albums: 5,
          artists: 2,
          elapsed: Duration(seconds: 10),
        ),
      );
      await tester.pumpWidget(app(c, const LibraryScanStatus()));
      expect(find.textContaining('50 / 100'), findsOneWidget);
      expect(find.textContaining('50%'), findsOneWidget);
      expect(find.textContaining('≈ 10s'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
    },
  );
  test(
    'real scanner reports artwork and metadata without downloading audio',
    () async {
      final server = await SubsonicFixture.start();
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('scan-activity');
      addTearDown(() => dir.delete(recursive: true));
      String? saved;
      final storage = NetworkStorageService(
        read: () async => saved,
        write: (s) async {
          saved = s;
        },
        ensureAccess: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(server.connection());
      final activities = <LibraryScanActivity>[];
      final scanner = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => dir,
        temporaryDirectory: () async => dir,
        onActivity: activities.add,
      );
      final output = await scanner.scan(
        'network://fixture/',
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      addTearDown(output.delete);
      expect(output.expectedCount, 1);
      expect(
        activities.map((a) => a.phase),
        containsAll([
          'connecting',
          'information',
          'catalogue',
          'artwork',
          'metadata',
          'indexing',
        ]),
      );
      expect(activities.last.processed, 1);
      expect(
        server.requests.where((r) => r.path.contains('/stream.')),
        isEmpty,
      );
      expect(activities.every((a) => a.total == null), isTrue);
    },
  );
}
