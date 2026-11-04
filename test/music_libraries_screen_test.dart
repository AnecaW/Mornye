import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/music_libraries_provider.dart';
import 'package:mornye/screens/music_libraries_screen.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('server-only library shows no local or unrelated source', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        libraryConnectionsProvider.overrideWith(
          (ref) async => [
            const NetworkConnection(
              id: 'one',
              name: 'Navidrome',
              protocol: NetworkProtocol.subsonic,
              address: 'https://one.example',
            ),
            const NetworkConnection(
              id: 'two',
              name: 'Other server',
              protocol: NetworkProtocol.subsonic,
              address: 'https://two.example',
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(musicLibrariesProvider.future);
    await container
        .read(musicLibrariesProvider.notifier)
        .save(name: 'Only Navidrome', local: false, connections: {'one'});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MusicLibrariesScreen(
            indexedLibrary: (_) => const Text('Indexed'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Navidrome'), findsOneWidget);
    expect(find.text('Other server'), findsNothing);
    expect(find.text('Music on this device'), findsNothing);
    expect(find.text('Only Navidrome'), findsWidgets);
    await container.read(musicLibrariesProvider.notifier).select('all');
    await tester.pumpAndSettle();
    expect(find.text('Other server'), findsOneWidget);
    expect(find.text('Music on this device'), findsOneWidget);
  });
}
