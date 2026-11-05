import 'package:flutter/material.dart';
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
    if (source == deviceMusicSource) return const SizedBox.shrink();
    final id = musicSourceConnectionId(source);
    final connections =
        ref.watch(librarySourceConnectionsProvider).value ??
        const <NetworkConnection>[];
    final stations =
        <({NetworkConnection server, Map<String, dynamic> station})>[];
    for (final connection in connections.where(
      (c) =>
          c.protocol == NetworkProtocol.subsonic && (id == null || c.id == id),
    )) {
      final rows =
          ref
              .watch(
                serverRadioStationsProvider((
                  connection: connection.id,
                  account: musicSourceAccount(connection),
                )),
              )
              .value ??
          const <Map<String, dynamic>>[];
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
    if (stations.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      leading: const Icon(Icons.radio_outlined),
      title: Text(context.l10n.libraryServerRadio),
      children: [
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
