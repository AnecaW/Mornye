import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/library_source_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_source_provider.dart';
import 'package:mornye/providers/server_library_data_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_service.dart' show PlayableMedia;
import 'package:mornye/services/network_storage_service.dart';

/// Server stations use the existing library page and the original player.
class LibraryServerRadio extends ConsumerWidget {
  const LibraryServerRadio({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(effectiveLibrarySourceProvider);

    final id = musicSourceConnectionId(source);
    final connections =
        ref.watch(librarySourceConnectionsProvider).value ??
        const <NetworkConnection>[];
    final stations =
        <({NetworkConnection server, Map<String, dynamic> station})>[];
    var loading = false;
    var unavailable = false;
    for (final connection in connections.where(
      (c) =>
          source != deviceMusicSource &&
          c.protocol == NetworkProtocol.subsonic &&
          (id == null || c.id == id),
    )) {
      final result = ref.watch(
        serverRadioStationsProvider((
          connection: connection.id,
          account: musicSourceAccount(connection),
        )),
      );
      loading |= result.isLoading;
      unavailable |= result.hasError;
      final rows = result.value ?? const <Map<String, dynamic>>[];
      for (final row in rows) {
        final uri = Uri.tryParse(row['streamUrl']?.toString() ?? '');
        if (uri != null &&
            {'http', 'https'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty) {
          stations.add((server: connection, station: row));
        }
      }
    }
    return Column(
      children: [
        if (loading) const LinearProgressIndicator(),
        if (stations.isEmpty && !loading)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              unavailable
                  ? context.l10n.libraryRadioUnavailable
                  : context.l10n.libraryRadioEmpty,
            ),
          ),
        if (unavailable && stations.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.l10n.libraryRadioUnavailable),
          ),
        for (final row in stations)
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text(row.station['name']?.toString() ?? ''),
            subtitle: Text(row.server.name),
            onTap: () => ref
                .read(musicPlayerControllerProvider)
                .playSingle(
                  PlayableMedia(
                    id: 'subsonic-radio://${row.server.id}/${row.station['id']}',
                    source: row.station['streamUrl'].toString(),
                    title: row.station['name']?.toString() ?? '',
                    artist: row.server.name,
                  ),
                ),
          ),
      ],
    );
  }
}

/// Same library-level navigation destination on mobile and desktop.
class LibraryRadioPage extends StatelessWidget {
  const LibraryRadioPage({super.key});
  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      AppSliverHeader.page(title: context.l10n.libraryServerRadio),
      const SliverToBoxAdapter(child: LibrarySourceSelector()),
      const SliverToBoxAdapter(child: LibraryServerRadio()),
    ],
  );
}
