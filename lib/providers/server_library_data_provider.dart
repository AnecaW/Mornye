import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/library_source_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/server_favourite_provider.dart';
import 'package:mornye/services/navidrome_library.dart';
import 'package:mornye/services/network_storage_service.dart';

typedef ServerSourceRequest = ({String connection, String account});
final serverRecentAccessProvider = FutureProvider.autoDispose
    .family<List<RecentAccessItem>, ServerSourceRequest>((ref, request) async {
      ref.watch(sourceRefreshTickProvider);
      ref.watch(serverLibraryChangesProvider);
      final connections = await ref.watch(
        librarySourceConnectionsProvider.future,
      );
      final connection = connections
          .where((c) => c.id == request.connection)
          .firstOrNull;
      if (connection == null ||
          connection.protocol != NetworkProtocol.subsonic ||
          musicSourceAccount(connection) != request.account) {
        return const [];
      }
      final library = NavidromeLibrary(
        connection,
        storage: ref.read(librarySourceStorageProvider),
      );
      final recent = await library.recentPlayed();
      final rows = <RecentAccessItem>[];
      for (final song in recent.songs) {
        final track = library.track(song);
        rows.add(
          RecentAccessItem(
            id: track.id,
            name: track.name,
            subtitle: track.artistName,
            imageUrl: track.coverUrl,
            type: RecentAccessType.track,
            accessedAt: subsonicPlayedAt(song['played'])!,
            providerId: 'subsonic:${connection.id}',
          ),
        );
      }
      // Some compatible servers only expose album-level history. Never invent song timestamps.
      if (rows.isEmpty) {
        for (final album in recent.albums) {
          final played = subsonicPlayedAt(album['played']);
          if (played == null) continue;
          final cover = album['coverArt']?.toString();
          rows.add(
            RecentAccessItem(
              id: Uri(
                scheme: 'subsonic-album',
                host: connection.id,
                pathSegments: [album['id'].toString()],
              ).toString(),
              name: album['name']?.toString() ?? '',
              subtitle: album['artist']?.toString(),
              imageUrl: cover == null
                  ? null
                  : NetworkStorageService.source(
                      connection.id,
                      subsonicCoverPath(cover),
                    ),
              type: RecentAccessType.album,
              accessedAt: played,
              providerId: 'subsonic:${connection.id}',
            ),
          );
        }
      }
      rows.sort((a, b) => b.accessedAt.compareTo(a.accessedAt));
      return rows.take(20).toList(growable: false);
    });

final selectedServerRecentItemsProvider = Provider<List<RecentAccessItem>>((
  ref,
) {
  final selected = ref.watch(effectiveLibrarySourceProvider);
  if (selected == deviceMusicSource) return const [];
  final id = musicSourceConnectionId(selected);
  final connections =
      ref.watch(librarySourceConnectionsProvider).value ??
      const <NetworkConnection>[];
  final items = <RecentAccessItem>[];
  for (final connection in connections.where(
    (c) => c.protocol == NetworkProtocol.subsonic && (id == null || c.id == id),
  )) {
    final value = ref.watch(
      serverRecentAccessProvider((
        connection: connection.id,
        account: musicSourceAccount(connection),
      )),
    );
    items.addAll(value.value ?? const []);
  }
  return items;
});

final serverRadioStationsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ServerSourceRequest>((
      ref,
      request,
    ) async {
      ref.watch(sourceRefreshTickProvider);
      ref.watch(serverLibraryChangesProvider);
      final connections = await ref.watch(
        librarySourceConnectionsProvider.future,
      );
      final connection = connections
          .where(
            (c) =>
                c.id == request.connection &&
                musicSourceAccount(c) == request.account,
          )
          .firstOrNull;
      if (connection == null ||
          connection.protocol != NetworkProtocol.subsonic) {
        return const [];
      }
      return NavidromeLibrary(
        connection,
        storage: ref.read(librarySourceStorageProvider),
      ).radios(fresh: true);
    });
