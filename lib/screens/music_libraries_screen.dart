import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_libraries_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/screens/navidrome_library_screen.dart';
import 'package:mornye/screens/network_storage_screen.dart';

class MusicLibrariesScreen extends ConsumerWidget {
  const MusicLibrariesScreen({super.key, required this.indexedLibrary});
  final WidgetBuilder indexedLibrary;
  Future<void> edit(
    BuildContext context,
    WidgetRef ref,
    List<NetworkConnection> connections, {
    MusicLibraryProfile? profile,
  }) async {
    final name = TextEditingController(text: profile?.name ?? '');
    var local = profile?.local ?? false;
    final selected = {...?profile?.connections};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            profile == null ? 'New music library' : 'Configure library',
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Library name',
                    ),
                  ),
                  CheckboxListTile(
                    value: local,
                    title: const Text('Music on this device'),
                    onChanged: (v) => setState(() => local = v ?? false),
                  ),
                  for (final connection in connections)
                    CheckboxListTile(
                      value: selected.contains(connection.id),
                      title: Text(connection.name),
                      subtitle: Text(connection.protocol.name),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          selected.add(connection.id);
                        } else {
                          selected.remove(connection.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(musicLibrariesProvider.notifier)
          .save(
            id: profile?.id,
            name: name.text,
            local: local,
            connections: selected,
          );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(musicLibrariesProvider);
    final connections = ref.watch(libraryConnectionsProvider);
    if (profiles.isLoading || connections.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (profiles.hasError || connections.hasError) {
      return Center(
        child: TextButton(
          onPressed: () {
            ref.invalidate(musicLibrariesProvider);
            ref.invalidate(libraryConnectionsProvider);
          },
          child: const Text('Could not load libraries. Retry'),
        ),
      );
    }
    final state = profiles.requireValue;
    final active = state.active;
    final saved = connections.requireValue;
    final visible = saved.where((c) => active.acceptsConnection(c.id)).toList();
    void open(NetworkConnection c) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => c.protocol == NetworkProtocol.subsonic
            ? NavidromeLibraryScreen(connection: c)
            : NetworkStorageScreen(connection: c),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: active.id,
            items: [
              for (final p in state.profiles)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (id) {
              if (id != null) {
                unawaited(ref.read(musicLibrariesProvider.notifier).select(id));
              }
            },
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Manage libraries',
            onSelected: (choice) async {
              if (!context.mounted) return;
              if (choice == 'new') {
                await edit(context, ref, saved);
                return;
              }
              if (context.mounted && choice == 'edit') {
                await edit(context, ref, saved, profile: active);
              }
              if (context.mounted && choice == 'delete') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Delete ${active.name}?'),
                    content: const Text(
                      'Music files and server data will be kept.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete library'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref
                      .read(musicLibrariesProvider.notifier)
                      .remove(active.id);
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'new', child: Text('Create library')),
              if (!const {'all', 'device'}.contains(active.id)) ...const [
                PopupMenuItem(
                  value: 'edit',
                  child: Text('Rename / configure sources'),
                ),
                PopupMenuItem(value: 'delete', child: Text('Delete library')),
              ],
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(libraryConnectionsProvider);
          await ref.read(libraryConnectionsProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ListTile(
              title: Text(active.name),
              subtitle: Text(
                active.all
                    ? 'All connected sources. Server data stays scoped to its account.'
                    : 'Only the sources configured for this library.',
              ),
            ),
            if (active.all || active.local)
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('Music on this device'),
                subtitle: const Text('Local files and saved downloads'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DeviceMusicScreen(),
                  ),
                ),
              ),
            for (final c in visible)
              ListTile(
                leading: Icon(
                  c.protocol == NetworkProtocol.subsonic
                      ? Icons.dns_outlined
                      : Icons.folder_outlined,
                ),
                title: Text(c.name),
                subtitle: Text(
                  c.protocol == NetworkProtocol.subsonic
                      ? 'Server music, playlists, favourites, history and radio'
                      : c.protocol.name,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(c),
              ),
            if (!active.all && !active.local && visible.isEmpty)
              const ListTile(
                title: Text('Configured source is unavailable'),
                subtitle: Text(
                  'Edit the library or reconnect the saved server.',
                ),
              ),
            if (active.all)
              ListTile(
                leading: const Icon(Icons.library_music),
                title: const Text('Indexed music'),
                subtitle: const Text('Existing combined library view'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: indexedLibrary),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.settings_input_component),
              title: const Text('Manage connections'),
              onTap: () =>
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const NetworkStorageScreen(),
                    ),
                  ).then((_) {
                    ref.invalidate(libraryConnectionsProvider);
                  }),
            ),
          ],
        ),
      ),
    );
  }
}

class DeviceMusicScreen extends ConsumerStatefulWidget {
  const DeviceMusicScreen({super.key});
  @override
  ConsumerState<DeviceMusicScreen> createState() => _DeviceMusicScreenState();
}

class _DeviceMusicScreenState extends ConsumerState<DeviceMusicScreen> {
  List<PlayableMedia> rows = [];
  bool loading = true, more = true;
  Object? error;
  String search = '';
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load({bool append = false}) async {
    setState(() => loading = true);
    try {
      final result = await LibraryDatabase.instance.getQueueTrackPage(
        QueueLibraryDbQuery(
          deviceOnly: true,
          includeSingleTrackAlbums: true,
          searchQuery: search,
          limit: 100,
          offset: append ? rows.length : 0,
        ),
      );
      final next = result.map((row) {
        final data = Map<String, dynamic>.from(row['item'] as Map);
        return row['source'] == 'local'
            ? playableFromLocal(LocalLibraryItem.fromJson(data))
            : playableFromHistory(DownloadHistoryItem.fromJson(data));
      }).toList();
      if (mounted) {
        setState(() {
          rows = append ? [...rows, ...next] : next;
          more = result.length == 100;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Music on this device')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(labelText: 'Search local music'),
            onSubmitted: (s) {
              search = s;
              unawaited(load());
            },
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          TextButton(onPressed: () => load(), child: Text('Retry: $error')),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => load(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 100),
              itemCount: rows.length + 1,
              itemBuilder: (_, index) => index == rows.length
                  ? more
                        ? TextButton(
                            onPressed: loading
                                ? null
                                : () => load(append: true),
                            child: const Text('Load more'),
                          )
                        : const SizedBox.shrink()
                  : ListTile(
                      title: Text(rows[index].title),
                      subtitle: Text(
                        '${rows[index].artist} · ${rows[index].album}',
                      ),
                      onTap: () => ref
                          .read(musicPlayerControllerProvider)
                          .playAll(rows, initialIndex: index),
                    ),
            ),
          ),
        ),
      ],
    ),
  );
}
