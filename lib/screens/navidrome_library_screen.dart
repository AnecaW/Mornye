import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/navidrome_library.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/screens/music_transfer_center.dart';

class NavidromeLibraryScreen extends ConsumerStatefulWidget {
  const NavidromeLibraryScreen({
    super.key,
    required this.connection,
    this.section = 'home',
    this.id,
    this.title,
  });
  final NetworkConnection connection;
  final String section;
  final String? id, title;
  @override
  ConsumerState<NavidromeLibraryScreen> createState() =>
      _NavidromeLibraryScreenState();
}

class _NavidromeLibraryScreenState extends ConsumerState<NavidromeLibraryScreen>
    with WidgetsBindingObserver {
  late final NavidromeLibrary library;
  List<Map<String, dynamic>> rows = [];
  ServerPlaylist? playlist;
  Object? error;
  bool loading = true, busy = false, more = false;
  int generation = 0;
  Timer? timer;
  String query = '';
  @override
  void initState() {
    super.initState();
    library = NavidromeLibrary(widget.connection, keepAlive: true);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
    timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && !busy && (ModalRoute.of(context)?.isCurrent ?? true)) {
        unawaited(load(fresh: true));
      }
    });
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    library.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) {
      unawaited(load(fresh: true));
    }
  }

  String get kind => switch (widget.section) {
    'artists' || 'starredArtists' => 'artist',
    'albums' ||
    'newest' ||
    'recent' ||
    'frequent' ||
    'starredAlbums' ||
    'artist' => 'album',
    'playlists' => 'playlist',
    'radios' => 'radio',
    'genres' => 'genre',
    _ => 'song',
  };
  Future<void> load({bool fresh = false, bool append = false}) async {
    final token = ++generation;
    setState(() => loading = true);
    try {
      final offset = append ? rows.length : 0;
      late List<Map<String, dynamic>> result;
      ServerPlaylist? loadedPlaylist;
      switch (widget.section) {
        case 'home':
          result = [];
        case 'artists':
          result = await library.artists(fresh: fresh);
        case 'albums':
        case 'newest':
        case 'recent':
        case 'frequent':
          result = await library.albums(
            type: widget.section == 'albums'
                ? 'alphabeticalByName'
                : widget.section,
            offset: offset,
            fresh: fresh,
          );
        case 'artist':
          result = await library.songs(
            'getArtist',
            {'id': widget.id!},
            'artist',
            'album',
            fresh: fresh,
          );
        case 'album':
          result = await library.songs(
            'getAlbum',
            {'id': widget.id!},
            'album',
            'song',
            fresh: fresh,
          );
        case 'playlists':
          result = await library.playlists(fresh: fresh);
        case 'playlist':
          loadedPlaylist = await library.playlist(widget.id!, fresh: fresh);
          result = loadedPlaylist.tracks;
        case 'genres':
          result = await library.songs(
            'getGenres',
            {},
            'genres',
            'genre',
            fresh: fresh,
          );
        case 'genre':
          result = await library.songs(
            'getSongsByGenre',
            {'genre': widget.id!, 'count': '100', 'offset': '$offset'},
            'songsByGenre',
            'song',
            fresh: fresh,
          );
        case 'radios':
          result = await library.radios(fresh: fresh);
        case 'starredSongs':
        case 'starredAlbums':
        case 'starredArtists':
          result = subsonicRows(
            (await library.starred(fresh: fresh))[switch (widget.section) {
              'starredAlbums' => 'album',
              'starredArtists' => 'artist',
              _ => 'song',
            }],
          );
        case 'songs':
          result = await library.songs(
            'search3',
            {
              'query': query,
              'songCount': '100',
              'songOffset': '$offset',
              'albumCount': '0',
              'artistCount': '0',
            },
            'searchResult3',
            'song',
            fresh: fresh,
          );
        default:
          throw StateError('Unknown library section');
      }
      if (!mounted || token != generation) return;
      setState(() {
        rows = append ? [...rows, ...result] : result;
        if (loadedPlaylist != null) playlist = loadedPlaylist;
        error = null;
        loading = false;
        more =
            const {
              'albums',
              'newest',
              'recent',
              'frequent',
              'songs',
              'genre',
            }.contains(widget.section) &&
            result.length == 100;
      });
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
      if (mounted) await load(fresh: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
        await load(fresh: true);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void open(String section, {String? id, String? title}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NavidromeLibraryScreen(
            connection: widget.connection,
            section: section,
            id: id,
            title: title,
          ),
        ),
      );
  Future<String?> text(String title, {String value = ''}) async {
    final controller = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return result;
  }

  Future<bool> confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> radioEditor([Map<String, dynamic>? station]) async {
    final name = await text(
      'Station name',
      value: station?['name']?.toString() ?? '',
    );
    if (name == null || !mounted) return;
    final url = await text(
      'Stream URL',
      value: station?['streamUrl']?.toString() ?? '',
    );
    if (url == null || !mounted) return;
    await action(
      () => library.saveRadio(name, url, id: station?['id']?.toString()),
    );
  }

  Future<void> play(int index) async {
    try {
      if (kind == 'radio') {
        final row = rows[index];
        final url = Uri.tryParse(row['streamUrl']?.toString() ?? '');
        if (url == null ||
            !const {'http', 'https'}.contains(url.scheme) ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty) {
          throw const FormatException('Invalid radio stream');
        }
        await ref
            .read(musicPlayerControllerProvider)
            .playSingle(
              PlayableMedia(
                id: 'radio:${widget.connection.id}/${row['id']}',
                source: url.toString(),
                title: row['name']?.toString() ?? '',
                artist: widget.connection.name,
              ),
            );
      } else {
        await ref
            .read(musicPlayerControllerProvider)
            .playAll(rows.map(library.playable).toList(), initialIndex: index);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> addSong(Map<String, dynamic> row) async {
    final lists = await library.playlists(fresh: true);
    if (!mounted) return;
    final id = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to server playlist'),
        children: [
          for (final p in lists)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p['id'].toString()),
              child: Text(p['name']?.toString() ?? ''),
            ),
        ],
      ),
    );
    if (id == null) return;
    await action(() async {
      final base = await library.playlist(id, fresh: true);
      await library.editPlaylist(
        base,
        songs: [...base.songIds, row['id'].toString()],
      );
    });
  }

  Future<void> menu(String command, Map<String, dynamic> row, int index) async {
    final id = row['id']?.toString() ?? '';
    if (command == 'editRadio') {
      await radioEditor(row);
      return;
    }
    if (command == 'add') {
      await addSong(row);
      return;
    }
    if (command == 'info') {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            row['title']?.toString() ?? row['name']?.toString() ?? 'Metadata',
          ),
          content: SingleChildScrollView(
            child: Text(
              row.entries
                  .where((e) => e.value is! Map && e.value is! List)
                  .map((e) => '${e.key}: ${e.value}')
                  .join('\n'),
            ),
          ),
        ),
      );
      return;
    }
    await action(() async {
      if (command == 'star') {
        await library.star(id, kind, row['starred'] == null);
      }
      if (command.startsWith('rate:')) {
        await library.rate(id, int.parse(command.substring(5)));
      }
      if (command == 'remove' && playlist != null) {
        final ids = playlist!.songIds..removeAt(index);
        await library.editPlaylist(playlist!, songs: ids);
      }
      if (command == 'rename') {
        final base = await library.playlist(id, fresh: true);
        if (!mounted) return;
        final name = await text('Rename server playlist', value: base.name);
        if (name != null) await library.editPlaylist(base, name: name);
      }
      if (command == 'delete' &&
          await confirm(
            'Delete this server ${kind == 'radio' ? 'station' : 'playlist'}?',
          )) {
        if (kind == 'radio') {
          await library.deleteRadio(id);
        } else {
          await library.editPlaylist(
            await library.playlist(id, fresh: true),
            delete: true,
          );
        }
      }
    });
  }

  Widget cover(Map<String, dynamic> row) {
    final id = row['coverArt']?.toString();
    return SizedBox(
      width: 48,
      height: 48,
      child: id == null
          ? Icon(kind == 'radio' ? Icons.radio : Icons.music_note)
          : PlayerArtwork(
              artUri: NetworkStorageService.source(
                widget.connection.id,
                subsonicCoverPath(id),
              ),
              colorScheme: Theme.of(context).colorScheme,
              cacheWidth: 96,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title =
        widget.title ??
        (widget.section == 'home' ? widget.connection.name : widget.section);
    final categories = <String, String>{
      'artists': 'Artists',
      'albums': 'Albums',
      'songs': 'Songs',
      'genres': 'Genres',
      'playlists': 'Server playlists',
      'starredSongs': 'Favourite songs',
      'starredAlbums': 'Favourite albums',
      'starredArtists': 'Favourite artists',
      'newest': 'Recently added',
      'recent': 'Recently played albums',
      'frequent': 'Most played albums',
      'radios': 'Internet radio',
    };
    Widget body;
    if (widget.section == 'home') {
      body = ListView(
        children: [
          ListTile(
            title: Text(widget.connection.name),
            subtitle: const Text('Server library · account-scoped data'),
          ),
          for (final item in categories.entries)
            ListTile(
              title: Text(item.value),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(item.key, title: item.value),
            ),
          ListTile(
            title: const Text('Transfers'),
            leading: const Icon(Icons.upload_file),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => MusicTransferCenter(server: widget.connection),
              ),
            ),
          ),
        ],
      );
    } else if (error != null && rows.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$error'),
              TextButton(
                onPressed: () => load(fresh: true),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else if (loading && rows.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      Widget rowWidget(int index) {
        final row = rows[index];
        final title =
            (row['title'] ?? row['name'] ?? row['value'] ?? row['genre'] ?? '')
                .toString();
        final subtitle = [
          if (row['artist'] != null) row['artist'],
          if (row['songCount'] != null) '${row['songCount']} tracks',
          if (row['playCount'] != null) '${row['playCount']} plays',
          if (row['played'] != null) 'Last played: ${row['played']}',
          if (row['userRating'] != null) '${row['userRating']}/5',
          if (kind == 'radio') row['streamUrl'],
        ].where((v) => v != null).join(' · ');
        return ListTile(
          key: ValueKey('${row['id'] ?? title}/$index'),
          leading: cover(row),
          title: Text(title),
          subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 2),
          onTap: () => switch (kind) {
            'artist' => open('artist', id: row['id'].toString(), title: title),
            'album' => open('album', id: row['id'].toString(), title: title),
            'playlist' => open(
              'playlist',
              id: row['id'].toString(),
              title: title,
            ),
            'genre' => open('genre', id: title, title: title),
            _ => unawaited(play(index)),
          },
          trailing: PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (value) => menu(value, row, index),
            itemBuilder: (_) => [
              if (const {'song', 'album', 'artist'}.contains(kind)) ...[
                PopupMenuItem(
                  value: 'star',
                  child: Text(
                    row['starred'] == null
                        ? 'Favourite on server'
                        : 'Remove server favourite',
                  ),
                ),
                if (kind != 'artist')
                  for (var n = 0; n <= 5; n++)
                    PopupMenuItem(
                      value: 'rate:$n',
                      child: Text(n == 0 ? 'Clear rating' : 'Rate $n/5'),
                    ),
              ],
              if (kind == 'song')
                const PopupMenuItem(
                  value: 'add',
                  child: Text('Add to server playlist'),
                ),
              if (widget.section == 'playlist' && playlist?.readOnly == false)
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove from playlist'),
                ),
              if (kind == 'radio')
                const PopupMenuItem(
                  value: 'editRadio',
                  child: Text('Edit station'),
                ),
              if (kind == 'playlist')
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
              if (kind == 'playlist' || kind == 'radio')
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              const PopupMenuItem(
                value: 'info',
                child: Text('Server metadata'),
              ),
            ],
          ),
        );
      }

      body = RefreshIndicator(
        onRefresh: () => load(fresh: true),
        child: widget.section == 'playlist' && playlist?.readOnly == false
            ? ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 100),
                itemCount: rows.length,
                itemBuilder: (_, index) => rowWidget(index),
                onReorderItem: (oldIndex, newIndex) {
                  if (busy) return;
                  final base = playlist!;
                  final ids = base.songIds;
                  ids.insert(newIndex, ids.removeAt(oldIndex));
                  unawaited(
                    action(() => library.editPlaylist(base, songs: ids)),
                  );
                },
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 100),
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: rows.length + 1,
                itemBuilder: (_, index) => index < rows.length
                    ? rowWidget(index)
                    : more
                    ? TextButton(
                        onPressed: loading ? null : () => load(append: true),
                        child: const Text('Load more'),
                      )
                    : rows.isEmpty
                    ? const ListTile(title: Text('No items'))
                    : const SizedBox.shrink(),
              ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (loading || busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            tooltip: 'Synchronize from server',
            onPressed: busy ? null : () => load(fresh: true),
            icon: const Icon(Icons.sync),
          ),
          if (widget.section == 'playlists')
            IconButton(
              tooltip: 'Create server playlist',
              icon: const Icon(Icons.add),
              onPressed: () async {
                final name = await text('New server playlist');
                if (name != null) {
                  await action(() => library.createPlaylist(name));
                }
              },
            ),
          if (widget.section == 'radios')
            IconButton(
              tooltip: 'Add server station',
              onPressed: () => radioEditor(),
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: Column(
        children: [
          if (widget.section == 'songs')
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Search server songs',
                  suffixIcon: Icon(Icons.search),
                ),
                onSubmitted: (value) {
                  query = value;
                  unawaited(load(fresh: true));
                },
              ),
            ),
          if (error != null && rows.isNotEmpty)
            MaterialBanner(
              content: Text(
                'Synchronization failed; showing the last loaded server data. $error',
              ),
              actions: [
                TextButton(
                  onPressed: () => load(fresh: true),
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
