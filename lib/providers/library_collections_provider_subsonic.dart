// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'library_collections_provider.dart';

String serverPlaylistKey(String connection, String playlist) => Uri(
  scheme: 'subsonic-playlist',
  host: connection,
  pathSegments: [playlist],
).toString();
({String connection, String playlist})? serverPlaylistIdentity(String id) {
  final uri = Uri.tryParse(id);
  if (uri?.scheme != 'subsonic-playlist' ||
      uri!.host.isEmpty ||
      uri.pathSegments.length != 1) {
    return null;
  }
  return (connection: uri.host, playlist: uri.pathSegments.single);
}

extension _SubsonicCollections on LibraryCollectionsNotifier {
  Future<NavidromeLibrary> _serverLibrary(String connection) async {
    final storage = ref.read(librarySourceStorageProvider);
    final account = await storage.connection(connection);
    if (account.protocol != NetworkProtocol.subsonic) {
      throw StateError('This is not a Subsonic server');
    }
    return NavidromeLibrary(account, storage: storage);
  }

  UserPlaylistCollection _serverPlaylistModel(
    NavidromeLibrary library,
    Map<String, dynamic> data, {
    bool loaded = false,
  }) {
    final id = serverPlaylistKey(library.connection.id, data['id'].toString());
    final changed =
        DateTime.tryParse(data['changed']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final songs = subsonicRows(data['entry']);
    final tracks = <CollectionTrackEntry>[];
    for (final (index, song) in songs.indexed) {
      final track = library.track(song);
      tracks.add(
        CollectionTrackEntry(
          key: 'server-occurrence:$index:${track.id}',
          track: track,
          addedAt: changed.add(Duration(milliseconds: index)),
        ),
      );
    }
    final cover = data['coverArt']?.toString();
    return UserPlaylistCollection(
      id: id,
      name: data['name']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(data['created']?.toString() ?? '') ?? changed,
      updatedAt: changed,
      tracks: tracks,
      tracksLoaded: loaded,
      remoteTrackCount: loaded
          ? tracks.length
          : (data['songCount'] as num?)?.toInt() ?? 0,
      previewCover: cover == null
          ? null
          : NetworkStorageService.source(
              library.connection.id,
              subsonicCoverPath(cover),
            ),
    );
  }

  Future<void> _loadServerPlaylist(String id) async {
    final identity = serverPlaylistIdentity(id)!;
    final library = await _serverLibrary(identity.connection);
    final snapshot = await library.playlist(identity.playlist, fresh: true);
    if (!ref.mounted) return;
    final currentAccount = await ref
        .read(librarySourceStorageProvider)
        .connection(identity.connection);
    if (!ref.mounted ||
        musicSourceAccount(currentAccount) !=
            musicSourceAccount(library.connection)) {
      return;
    }
    _serverSnapshots[id] = snapshot;
    _serverOwners[id] = musicSourceAccount(library.connection);
    final model = _serverPlaylistModel(library, snapshot.data, loaded: true);
    _serverRows[identity.connection] = [
      for (final row
          in _serverRows[identity.connection] ?? <UserPlaylistCollection>[])
        if (row.id == id) model else row,
    ];
    if (!(_serverRows[identity.connection]?.any((row) => row.id == id) ??
        false)) {
      _serverRows[identity.connection] = [
        ...?_serverRows[identity.connection],
        model,
      ];
    }
    _publishServerPlaylists();
  }

  void _publishServerPlaylists() {
    if (!ref.mounted) return;
    state = state.copyWith(
      playlists: [
        ...state.playlists.where((p) => serverPlaylistIdentity(p.id) == null),
        ..._serverRows.values.expand((p) => p),
      ],
    );
    _invalidatePlaylistPickerSummaries();
  }

  Future<void> _refreshServerPlaylists() => _serverRefresh ??= () async {
    await _ensureLoaded();
    final connections = await ref.read(librarySourceConnectionsProvider.future);
    if (!ref.mounted) return;
    final servers = connections
        .where((c) => c.protocol == NetworkProtocol.subsonic)
        .toList();
    final ids = servers.map((c) => c.id).toSet();
    _serverRows.removeWhere((id, _) => !ids.contains(id));
    for (final connection in servers) {
      final owner = musicSourceAccount(connection);
      if (_serverConnectionOwners[connection.id] != owner) {
        _serverRows.remove(connection.id);
        _serverSnapshots.removeWhere(
          (id, _) => serverPlaylistIdentity(id)?.connection == connection.id,
        );
        _serverOwners.removeWhere(
          (id, _) => serverPlaylistIdentity(id)?.connection == connection.id,
        );
        _serverConnectionOwners[connection.id] = owner;
        _publishServerPlaylists();
      }
      final library = NavidromeLibrary(
        connection,
        storage: ref.read(librarySourceStorageProvider),
      );
      try {
        final data = await library.playlists(fresh: true);
        if (!ref.mounted) return;
        final next = <UserPlaylistCollection>[];
        for (final row in data) {
          final id = serverPlaylistKey(connection.id, row['id'].toString());
          final cached = _serverSnapshots[id];
          if (cached != null &&
              _serverOwners[id] == musicSourceAccount(connection) &&
              cached.data['changed'] == row['changed']) {
            next.add(
              _serverPlaylistModel(library, {
                ...cached.data,
                ...row,
                'entry': cached.tracks,
              }, loaded: true),
            );
          } else if (cached != null &&
              _serverOwners[id] == musicSourceAccount(connection)) {
            final fresh = await library.playlist(
              row['id'].toString(),
              fresh: true,
            );
            if (!ref.mounted) return;
            _serverSnapshots[id] = fresh;
            next.add(_serverPlaylistModel(library, fresh.data, loaded: true));
          } else {
            _serverSnapshots.remove(id);
            _serverOwners.remove(id);
            next.add(_serverPlaylistModel(library, row));
          }
        }
        final current = await ref
            .read(librarySourceStorageProvider)
            .connection(connection.id);
        if (!ref.mounted) return;
        if (musicSourceAccount(current) != owner) continue;
        _serverRows[connection.id] = next;
      } catch (error) {
        _log.w(
          'Server playlists temporarily unavailable; retaining their last snapshot',
        );
      }
    }
    _publishServerPlaylists();
  }().whenComplete(() => _serverRefresh = null);

  Future<({NavidromeLibrary library, ServerPlaylist snapshot})> _serverEdit(
    String id,
  ) async {
    final identity = serverPlaylistIdentity(id)!;
    if (!_serverSnapshots.containsKey(id)) await _loadServerPlaylist(id);
    final library = await _serverLibrary(identity.connection);
    if (_serverOwners[id] != musicSourceAccount(library.connection)) {
      throw StateError('The server account changed. Refresh this playlist.');
    }
    return (library: library, snapshot: _serverSnapshots[id]!);
  }

  Future<String> _createServerPlaylist(String connection, String name) async {
    final library = await _serverLibrary(connection);
    final before = (await library.playlists(
      fresh: true,
    )).map((r) => r['id'].toString()).toSet();
    final response = await library.write('createPlaylist', {
      'name': name.trim(),
    });
    final returned = subsonicObject(response['playlist']);
    String? id = returned['id']?.toString();
    if (id == null) {
      final created = (await library.playlists(fresh: true))
          .where(
            (r) =>
                !before.contains(r['id'].toString()) &&
                r['name'] == name.trim(),
          )
          .toList();
      if (created.length == 1) id = created.single['id'].toString();
    }
    await _refreshServerPlaylists();
    if (id == null) {
      throw StateError(
        'The server may have created the playlist. Refresh before retrying.',
      );
    }
    return serverPlaylistKey(connection, id);
  }

  Future<PlaylistAddBatchResult> _addServerTracks(
    String id,
    Iterable<Track> tracks, {
    bool preserveOccurrences = false,
  }) async {
    final target = await _serverEdit(id);
    final ids = [...target.snapshot.songIds];
    var added = 0, duplicates = 0;
    for (final track in tracks) {
      final uri = Uri.tryParse(
        track.id.startsWith('network://') ? track.id : track.source ?? '',
      );
      final song = uri == null
          ? null
          : subsonicSongIdFromPath(uri.pathSegments.join('/'));
      if (uri?.host != target.library.connection.id || song == null) {
        throw StateError(
          'Upload this music to the selected server before adding it to its playlist.',
        );
      }
      if (!preserveOccurrences && ids.contains(song)) {
        duplicates++;
        continue;
      }
      ids.add(song);
      added++;
    }
    if (added > 0) {
      await target.library.editPlaylist(target.snapshot, songs: ids);
      await _loadServerPlaylist(id);
    }
    return PlaylistAddBatchResult(
      addedCount: added,
      alreadyInPlaylistCount: duplicates,
    );
  }

  Future<int> _removeServerTracks(String id, Set<String> keys) async {
    final target = await _serverEdit(id);
    final current = state.playlistById(id)!;
    final keep = <String>[];
    var removed = 0;
    for (final (index, row) in current.tracks.indexed) {
      if (keys.contains(row.key)) {
        removed++;
      } else {
        keep.add(target.snapshot.songIds[index]);
      }
    }
    if (removed > 0) {
      await target.library.editPlaylist(target.snapshot, songs: keep);
      await _loadServerPlaylist(id);
    }
    return removed;
  }

  Future<bool> _reorderServerTracks(String id, List<String> keys) async {
    final target = await _serverEdit(id);
    final rows = state.playlistById(id)!.tracks;
    final indexes = {for (final (index, row) in rows.indexed) row.key: index};
    if (keys.length != rows.length ||
        keys.toSet().length != rows.length ||
        !keys.every(indexes.containsKey)) {
      return false;
    }
    await target.library.editPlaylist(
      target.snapshot,
      songs: [for (final key in keys) target.snapshot.songIds[indexes[key]!]],
    );
    await _loadServerPlaylist(id);
    return true;
  }
}

final scopedLibraryCollectionsProvider = Provider<LibraryCollectionsState>((
  ref,
) {
  final state = ref.watch(libraryCollectionsProvider);
  final source = ref.watch(effectiveLibrarySourceProvider);
  final id = musicSourceConnectionId(source);
  bool belongs(CollectionTrackEntry entry) {
    final uri = Uri.tryParse(entry.track.source ?? entry.track.id);
    if (source == allMusicSources) return true;
    if (source == deviceMusicSource) return uri?.scheme != 'network';
    return uri?.scheme == 'network' && uri?.host == id;
  }

  return state.copyWith(
    wishlist: state.wishlist.where(belongs).toList(growable: false),
    loved: state.loved.where(belongs).toList(growable: false),
    favoriteArtists: id == null ? state.favoriteArtists : const [],
    playlists: state.playlists
        .where((p) {
          final server = serverPlaylistIdentity(p.id);
          return source == allMusicSources ||
              (source == deviceMusicSource
                  ? server == null
                  : server?.connection == id);
        })
        .toList(growable: false),
  );
});
