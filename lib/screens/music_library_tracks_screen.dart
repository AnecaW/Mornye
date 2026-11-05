import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_libraries_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/scoped_music_catalogue.dart';
import 'package:mornye/widgets/player_artwork.dart';

class MusicLibraryTracksScreen extends ConsumerStatefulWidget {
  const MusicLibraryTracksScreen({super.key, required this.profile});
  final MusicLibraryProfile profile;
  @override
  ConsumerState<MusicLibraryTracksScreen> createState() =>
      _MusicLibraryTracksScreenState();
}

class _MusicLibraryTracksScreenState
    extends ConsumerState<MusicLibraryTracksScreen> {
  ScopedMusicCatalogue? catalogue;
  bool loading = true;
  Object? error;
  String query = '';
  int generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(open());
  }

  Future<void> open() async {
    try {
      final result = await ScopedMusicCatalogue.open(widget.profile);
      if (!mounted) {
        result.close();
        return;
      }
      catalogue = result;
      await load(reset: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  Future<void> load({bool reset = false, bool retryFailed = false}) async {
    final data = catalogue;
    if (data == null) return;
    final ticket = ++generation;
    setState(() => loading = true);
    await data.load(
      reset: reset,
      retryFailed: retryFailed,
      query: query,
      changed: () {
        if (mounted && ticket == generation) setState(() {});
      },
    );
    if (mounted && ticket == generation) setState(() => loading = false);
  }

  @override
  void dispose() {
    catalogue?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = catalogue;
    final tracks = data?.tracks ?? const <CatalogueTrack>[];
    return Scaffold(
      appBar: AppBar(title: Text('${widget.profile.name} · Songs')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Search this library',
                suffixIcon: Icon(Icons.search),
              ),
              onSubmitted: (value) {
                query = value;
                unawaited(load(reset: true));
              },
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            TextButton(onPressed: open, child: Text('Retry: $error')),
          if (data?.errors.isNotEmpty == true)
            MaterialBanner(
              content: Text(
                data!.errors.entries
                    .map((e) => '${e.key}: ${e.value}')
                    .join('\n'),
              ),
              actions: [
                TextButton(
                  onPressed: loading ? null : () => load(retryFailed: true),
                  child: const Text('Retry failed sources'),
                ),
              ],
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => load(reset: true),
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 100),
                itemCount: tracks.length + 1,
                itemBuilder: (_, index) {
                  if (index == tracks.length) {
                    if (data?.more == true) {
                      return TextButton(
                        onPressed: loading ? null : () => load(),
                        child: const Text('Load more'),
                      );
                    }
                    if (tracks.isEmpty && !loading) {
                      return const ListTile(
                        title: Text('No music in this library'),
                        subtitle: Text(
                          'Non-Subsonic folders must be indexed first; use the source browser to add them to the library.',
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  }
                  final track = tracks[index];
                  return ListTile(
                    key: ValueKey(track.media.source),
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: PlayerArtwork(
                        artUri:
                            track.media.coverReference ?? track.media.artUri,
                        colorScheme: Theme.of(context).colorScheme,
                        cacheWidth: 96,
                      ),
                    ),
                    title: Text(track.media.title),
                    subtitle: Text(
                      '${track.media.artist} · ${track.sourceName}',
                    ),
                    onTap: () => ref
                        .read(musicPlayerControllerProvider)
                        .playAll(
                          tracks.map((t) => t.media).toList(),
                          initialIndex: index,
                        ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
