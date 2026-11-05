import 'dart:math' as math;
import 'package:mornye/services/navidrome_library.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/providers/music_libraries_provider.dart';

class CatalogueSource {
  CatalogueSource({
    required this.id,
    required this.name,
    required this.fetch,
    this.close,
  });
  final String id, name;
  final Future<List<PlayableMedia>> Function(int offset, String query) fetch;
  final void Function()? close;
  int offset = 0;
  bool more = true;
  Object? error;
}

class CatalogueTrack {
  const CatalogueTrack(this.media, this.sourceName);
  final PlayableMedia media;
  final String sourceName;
}

/// Paged fan-in with bounded concurrency. Never match tracks by title/artist:
/// equal IDs belonging to different accounts remain different sources.
class ScopedMusicCatalogue {
  ScopedMusicCatalogue(this.sources, {this.sourceLabels = const {}});
  final Map<String, String> sourceLabels;
  final List<CatalogueSource> sources;
  final List<CatalogueTrack> tracks = [];
  int _epoch = 0;
  bool get more => sources.any((s) => s.more);
  Map<String, Object> get errors => {
    for (final source in sources)
      if (source.error != null) source.name: source.error!,
  };
  Future<void> load({
    bool reset = false,
    bool retryFailed = false,
    String query = '',
    void Function()? changed,
  }) async {
    if (reset) {
      _epoch++;
      tracks.clear();
      for (final s in sources) {
        s.offset = 0;
        s.more = true;
        s.error = null;
      }
    }
    final epoch = _epoch;
    final active = sources
        .where((s) => retryFailed ? s.error != null : s.more)
        .toList();
    var next = 0;
    await Future.wait(
      List.generate(math.min(4, active.length), (_) async {
        while (next < active.length && epoch == _epoch) {
          final source = active[next++];
          try {
            final page = await source.fetch(source.offset, query);
            if (epoch != _epoch) return;
            source.offset += page.length;
            source.more = page.length == 100;
            source.error = null;
            final existing = tracks.map((t) => t.media.source).toSet();
            for (final media in page) {
              if (existing.add(media.source)) {
                tracks.add(
                  CatalogueTrack(
                    media,
                    sourceLabels[Uri.tryParse(media.source)?.host] ??
                        source.name,
                  ),
                );
              }
            }
          } catch (error) {
            if (epoch != _epoch) return;
            source.error = error;
          }
          changed?.call();
        }
      }),
    );
  }

  void close() {
    _epoch++;
    for (final source in sources) {
      source.close?.call();
    }
  }

  static Future<ScopedMusicCatalogue> open(
    MusicLibraryProfile profile, {
    NetworkStorageService? storage,
  }) async {
    final service = storage ?? NetworkStorageService.instance;
    final connections = (await service.connections())
        .where((c) => profile.acceptsConnection(c.id))
        .toList();
    final sources = <CatalogueSource>[];
    for (final connection in connections.where(
      (c) => c.protocol == NetworkProtocol.subsonic,
    )) {
      final server = NavidromeLibrary(
        connection,
        storage: service,
        keepAlive: true,
      );
      sources.add(
        CatalogueSource(
          id: connection.id,
          name: connection.name,
          close: server.close,
          fetch: (offset, query) async {
            final rows = await server.songs(
              'search3',
              {
                'query': query,
                'songOffset': '$offset',
                'songCount': '100',
                'albumCount': '0',
                'artistCount': '0',
              },
              'searchResult3',
              'song',
            );
            return rows.map(server.playable).toList();
          },
        ),
      );
    }
    final indexed = connections
        .where((c) => c.protocol != NetworkProtocol.subsonic)
        .map((c) => c.id)
        .toSet();
    if (profile.all || profile.local || indexed.isNotEmpty) {
      sources.add(
        CatalogueSource(
          id: 'indexed',
          name: 'On this device / indexed folders',
          fetch: (offset, query) async {
            final rows = await LibraryDatabase.instance.getQueueTrackPage(
              QueueLibraryDbQuery(
                limit: 100,
                offset: offset,
                networkScope: indexed,
                includeDevice: profile.all || profile.local,
                searchQuery: query,
                includeSingleTrackAlbums: true,
              ),
            );
            return rows.map((row) {
              final data = Map<String, dynamic>.from(row['item'] as Map);
              return row['source'] == 'local'
                  ? playableFromLocal(LocalLibraryItem.fromJson(data))
                  : playableFromHistory(DownloadHistoryItem.fromJson(data));
            }).toList();
          },
        ),
      );
    }
    return ScopedMusicCatalogue(
      sources,
      sourceLabels: {for (final c in connections) c.id: c.name},
    );
  }
}
