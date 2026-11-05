import 'package:flutter/material.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/widgets/library_scan_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_source_provider.dart';
import 'package:mornye/screens/navidrome_transfers_page.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/controllers/clickable_metadata.dart' show pushPage;

/// One selector added to the original Library header; no alternate navigation.
class LibrarySourceSelector extends ConsumerWidget {
  const LibrarySourceSelector({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(effectiveLibrarySourceProvider);
    final connections =
        ref.watch(librarySourceConnectionsProvider).value ??
        const <NetworkConnection>[];
    final id = musicSourceConnectionId(selected);
    final server = connections.where((c) => c.id == id).firstOrNull;
    final synchronization = ref.watch(librarySourceSyncProvider(selected));
    final l10n = context.l10n;
    final label = selected == allMusicSources
        ? l10n.libraryAllSources
        : selected == deviceMusicSource
        ? l10n.libraryDeviceSource
        : server?.name ?? l10n.librarySourceUnavailable;
    final localEnabled = ref.watch(
      settingsProvider.select((s) => s.localLibraryEnabled),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: PopupMenuButton<String>(
                    tooltip: l10n.libraryChooseSource,
                    onSelected: (source) async {
                      if (source == 'manage-sources') {
                        await _manageSources(context, ref);
                        return;
                      }
                      await ref
                          .read(selectedLibrarySourceProvider.notifier)
                          .select(source);
                    },
                    itemBuilder: (context) => [
                      CheckedPopupMenuItem(
                        value: allMusicSources,
                        checked: selected == allMusicSources,
                        child: _option(
                          Icons.library_music_outlined,
                          l10n.libraryAllSources,
                        ),
                      ),
                      if (localEnabled)
                        CheckedPopupMenuItem(
                          value: deviceMusicSource,
                          checked: selected == deviceMusicSource,
                          child: _option(
                            Icons.smartphone_outlined,
                            l10n.libraryDeviceSource,
                          ),
                        ),
                      for (final connection in connections)
                        CheckedPopupMenuItem(
                          value: serverMusicSource(connection.id),
                          checked: selected == serverMusicSource(connection.id),
                          child: _option(Icons.dns_outlined, connection.name),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'manage-sources',
                        child: _option(Icons.tune, l10n.libraryManageSources),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.library_music_outlined, size: 20),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(label, overflow: TextOverflow.ellipsis),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (synchronization.isLoading &&
                  connections.any(
                    (c) =>
                        c.protocol == NetworkProtocol.subsonic &&
                        (id == null || c.id == id),
                  ))
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (synchronization.hasError)
                Tooltip(
                  message: l10n.librarySourceUnavailable,
                  child: const Icon(Icons.cloud_off_outlined, size: 20),
                ),
              IconButton(
                tooltip: l10n.networkRefresh,
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  ref
                      .read(localLibraryProvider.notifier)
                      .resumeCancelledScans();
                  ref.invalidate(librarySourceConnectionsProvider);
                  ref.invalidate(librarySourceSyncProvider(selected));
                },
              ),
              if (server?.protocol == NetworkProtocol.subsonic)
                IconButton(
                  tooltip: l10n.libraryUploadMusic,
                  icon: const Icon(Icons.upload_file_outlined),
                  onPressed: () async {
                    await pushPage<void>(
                      context,
                      (_) => NavidromeTransfersPage(server: server!),
                    );
                    if (context.mounted) {
                      ref.invalidate(librarySourceSyncProvider(selected));
                    }
                  },
                ),
            ],
          ),
        ),
        if (localEnabled || connections.isNotEmpty) const LibraryScanStatus(),
      ],
    );
  }

  Widget _option(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 10),
      Flexible(child: Text(label)),
    ],
  );

  Future<void> _manageSources(BuildContext context, WidgetRef ref) async {
    final connections = await ref.read(
      savedLibrarySourceConnectionsProvider.future,
    );
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final local = ref.watch(
            settingsProvider.select((s) => s.localLibraryEnabled),
          );
          final sources = ref.watch(
            localLibraryProvider.select((s) => s.sources),
          );
          return AlertDialog(
            title: Text(context.l10n.libraryManageSources),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.smartphone_outlined),
                      title: Text(context.l10n.libraryDeviceSource),
                      value: local,
                      onChanged: (value) => ref
                          .read(settingsProvider.notifier)
                          .setLocalLibraryEnabled(value),
                    ),
                    for (final connection in connections)
                      Builder(
                        builder: (context) {
                          final source = sources
                              .where(
                                (s) =>
                                    s.path ==
                                    NetworkStorageService.source(
                                      connection.id,
                                      '',
                                    ),
                              )
                              .firstOrNull;
                          return SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            secondary: const Icon(Icons.dns_outlined),
                            title: Text(connection.name),
                            value: source?.enabled ?? true,
                            onChanged: (value) async {
                              final library = ref.read(
                                localLibraryProvider.notifier,
                              );
                              final existing =
                                  source ??
                                  await library.addSource(
                                    path: NetworkStorageService.source(
                                      connection.id,
                                      '',
                                    ),
                                    displayName: connection.name,
                                  );
                              await library.setSourceEnabled(
                                existing.id,
                                value,
                              );
                            },
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(MaterialLocalizations.of(context).closeButtonLabel),
              ),
            ],
          );
        },
      ),
    );
  }
}
