import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/network_audio_cache.dart';
import 'package:mornye/widgets/network_audio_cache_settings.dart';

void main() {
  testWidgets('cache storage failure is visible and retry recovers', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('cache-settings-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    var fail = true;
    final cache = NetworkAudioCache(
      directory: () async {
        if (fail) throw const FileSystemException('Unavailable');
        return directory;
      },
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NetworkAudioCacheSettings(cache: cache),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    expect(tester.takeException(), isNull);
    expect(find.text('Music cache storage is unavailable'), findsOneWidget);
    expect(
      tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .every((tile) => tile.onChanged == null),
      isTrue,
    );
    fail = false;
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Retry reading music cache'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    expect(tester.takeException(), isNull);
    expect(find.text('Music cache storage is unavailable'), findsNothing);
    expect(
      tester
          .widget<SwitchListTile>(find.byType(SwitchListTile).first)
          .onChanged,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
