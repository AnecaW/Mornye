import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/music_libraries_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('profiles create configure rename switch delete and persist', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(musicLibrariesProvider.future);
    final notifier = container.read(musicLibrariesProvider.notifier);
    await notifier.save(
      name: 'Navidrome',
      local: false,
      connections: {'server-one'},
    );
    var state = container.read(musicLibrariesProvider).requireValue;
    final id = state.selected;
    expect(state.active.acceptsConnection('server-one'), isTrue);
    expect(state.active.acceptsConnection('server-two'), isFalse);
    expect(state.active.acceptsLocalPath('/local/song.flac'), isFalse);
    await notifier.save(
      id: id,
      name: 'My server',
      local: false,
      connections: {'server-one', 'server-two'},
    );
    final second = ProviderContainer();
    addTearDown(second.dispose);
    expect(
      (await second.read(musicLibrariesProvider.future)).active.name,
      'My server',
    );
    await notifier.select('device');
    state = container.read(musicLibrariesProvider).requireValue;
    expect(state.active.acceptsLocalPath('/local/song.flac'), isTrue);
    expect(state.active.acceptsLocalPath('network://server/song'), isFalse);
    expect(state.active.acceptsConnection('server-one'), isFalse);
    await notifier.select(id);
    await notifier.remove(id);
    expect(container.read(musicLibrariesProvider).requireValue.selected, 'all');
    await expectLater(notifier.remove('all'), throwsArgumentError);
  });
  test(
    'all music includes connected servers while single-server scope stays isolated',
    () {
      const all = MusicLibraryProfile(id: 'all', name: 'All');
      expect(all.acceptsConnection('one'), isTrue);
      expect(all.acceptsConnection('two'), isTrue);
      const one = MusicLibraryProfile(
        id: 'one',
        name: 'One',
        connections: {'one'},
      );
      expect(one.acceptsConnection('two'), isFalse);
    },
  );
}
