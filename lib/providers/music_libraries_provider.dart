import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/network_storage_service.dart';

class MusicLibraryProfile {
  const MusicLibraryProfile({
    required this.id,
    required this.name,
    this.local = false,
    this.connections = const {},
  });
  final String id, name;
  final bool local;
  final Set<String> connections;
  bool get all => id == 'all';
  bool acceptsConnection(String id) => all || connections.contains(id);
  bool acceptsLocalPath(String path) =>
      (all || local) && !path.startsWith('network://');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'local': local,
    'connections': connections.toList(),
  };
  factory MusicLibraryProfile.fromJson(Map<String, dynamic> data) =>
      MusicLibraryProfile(
        id: data['id'] as String,
        name: data['name'] as String,
        local: data['local'] == true,
        connections: (data['connections'] as List).cast<String>().toSet(),
      );
}

class MusicLibrariesState {
  const MusicLibrariesState({
    this.profiles = const [
      MusicLibraryProfile(id: 'all', name: 'All music', local: true),
      MusicLibraryProfile(id: 'device', name: 'On this device', local: true),
    ],
    this.selected = 'all',
  });
  final List<MusicLibraryProfile> profiles;
  final String selected;
  MusicLibraryProfile get active =>
      profiles.where((p) => p.id == selected).firstOrNull ?? profiles.first;
}

class MusicLibraries extends AsyncNotifier<MusicLibrariesState> {
  static const key = 'music_libraries_v1';
  Future<void> _tail = Future.value();
  @override
  Future<MusicLibrariesState> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return const MusicLibrariesState();
    try {
      final data = jsonDecode(raw) as Map;
      final custom = (data['profiles'] as List)
          .map(
            (e) => MusicLibraryProfile.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .where((p) => p.id != 'all' && p.id != 'device')
          .toList();
      return MusicLibrariesState(
        profiles: [...const MusicLibrariesState().profiles, ...custom],
        selected: data['selected'] as String? ?? 'all',
      );
    } catch (_) {
      return const MusicLibrariesState();
    }
  }

  Future<void> _change(
    MusicLibrariesState Function(MusicLibrariesState) action,
  ) {
    final result = _tail.then((_) async {
      final current = state.value ?? await future;
      final next = action(current);
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        key,
        jsonEncode({
          'profiles': next.profiles.map((p) => p.toJson()).toList(),
          'selected': next.selected,
        }),
      )) {
        throw StateError('Could not save library settings');
      }
      if (ref.mounted) state = AsyncData(next);
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> select(String id) => _change((s) {
    if (!s.profiles.any((p) => p.id == id)) {
      throw ArgumentError('Unknown library');
    }
    return MusicLibrariesState(profiles: s.profiles, selected: id);
  });
  Future<void> save({
    String? id,
    required String name,
    required bool local,
    required Set<String> connections,
  }) => _change((s) {
    if (name.trim().isEmpty || (!local && connections.isEmpty)) {
      throw ArgumentError('Choose a name and at least one source');
    }
    if (id == 'all' || id == 'device') throw ArgumentError('Built-in library');
    final profile = MusicLibraryProfile(
      id: id ?? NetworkStorageService.newId(),
      name: name.trim(),
      local: local,
      connections: Set.unmodifiable(connections),
    );
    return MusicLibrariesState(
      profiles: [...s.profiles.where((p) => p.id != profile.id), profile],
      selected: profile.id,
    );
  });
  Future<void> remove(String id) => _change((s) {
    if (id == 'all' || id == 'device') throw ArgumentError('Built-in library');
    return MusicLibrariesState(
      profiles: s.profiles.where((p) => p.id != id).toList(),
      selected: s.selected == id ? 'all' : s.selected,
    );
  });
}

final musicLibrariesProvider =
    AsyncNotifierProvider<MusicLibraries, MusicLibrariesState>(
      MusicLibraries.new,
    );
final libraryConnectionsProvider = FutureProvider<List<NetworkConnection>>(
  (ref) => NetworkStorageService.instance.connections(),
);

/// A single server-only profile can route desktop shortcuts without ever
/// entering the combined on-device index.
final activeServerLibraryProvider = Provider<NetworkConnection?>((ref) {
  final profile = ref.watch(musicLibrariesProvider).value?.active;
  if (profile == null ||
      profile.all ||
      profile.local ||
      profile.connections.length != 1) {
    return null;
  }
  return ref
      .watch(libraryConnectionsProvider)
      .value
      ?.where(
        (c) =>
            profile.acceptsConnection(c.id) &&
            c.protocol == NetworkProtocol.subsonic,
      )
      .firstOrNull;
});
String? serverLibrarySectionForSidebar(String id) => switch (id) {
  'recent' => 'newest',
  'played' => 'recent',
  'radio' => 'radios',
  'artists' ||
  'albums' ||
  'songs' ||
  'playlists' ||
  'starredSongs' ||
  'starredAlbums' ||
  'starredArtists' => id,
  _ => null,
};
