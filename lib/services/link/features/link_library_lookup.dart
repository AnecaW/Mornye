import 'package:mornye/services/music_library_scope.dart';
import 'package:mornye/services/library_source_scope.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/features/link_track_resolver.dart';

/// The Library song each of [tracks] (a playlist's) plays from, matched as
/// playing them matches (`resolveTrackFiles`): a scanned Library row first
/// when [includeLocal], else a download. Tracks without one are left out.
Future<List<UnifiedLibraryItem>> linkLibraryItemsFor(
  List<Track> tracks, {
  required bool includeLocal,
  LibraryDatabase? library,
  HistoryDatabase? history,
  MusicLibraryScope? scope,
}) async {
  if (tracks.isEmpty) return const [];
  final historyDb = history ?? HistoryDatabase.instance;
  final boundary = scope?.apply(
    QueueLibraryDbQuery(includeLocal: includeLocal),
  );
  final lookups = [
    for (final track in tracks)
      LocalLibraryBatchLookupRequest(
        filePath: (track.source ?? '').startsWith('network://')
            ? track.source
            : track.id.startsWith('network://')
            ? track.id
            : null,
        id: (track.source ?? '').toLowerCase() == 'local' ? track.id : null,
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      ),
  ];
  final database = library ?? LibraryDatabase.instance;
  final local = (boundary?.includeLocal ?? includeLocal)
      ? boundary == null
            ? await database.findExistingBatch(lookups)
            : await database.findExistingBatchScoped(lookups, boundary)
      : List<Map<String, dynamic>?>.filled(tracks.length, null);
  final matches = await historyDb.findExistingTracks([
    for (final track in tracks)
      HistoryLookupRequest(
        spotifyId: track.id,
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      ),
  ]);
  final downloads = await historyDb.getByIds({
    for (var i = 0; i < tracks.length; i++)
      if (local[i] == null)
        if (matches[i]?['id'] case final String id) id,
  });
  return [
    for (var i = 0; i < tracks.length; i++)
      if (local[i] case final row?)
        UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(row))
      else if (downloads[matches[i]?['id']] case final row?
          when libraryScopeAllowsPath(
            boundary,
            row['file_path'] as String? ?? row['filePath'] as String? ?? '',
          ))
        UnifiedLibraryItem.fromDownloadHistory(
          DownloadHistoryItem.fromJson(row),
        ),
  ];
}

/// [LinkLibraryLookup] over the download history and, when the Library is
/// on, the scanned Library rows.
class LinkDatabaseLookup implements LinkLibraryLookup {
  LinkDatabaseLookup({
    required DownloadHistoryNotifier Function() history,
    required this.library,
    required bool Function() includeLibrary,
    this.scope,
  }) : _history = history,
       _includeLibrary = includeLibrary;

  final DownloadHistoryNotifier Function() _history;
  final LibraryDatabase library;
  final bool Function() _includeLibrary;
  final MusicLibraryScope? Function()? scope;
  QueueLibraryDbQuery? get boundary =>
      scope?.call()?.apply(const QueueLibraryDbQuery());
  bool allows(String path, {bool indexed = false}) =>
      libraryScopeAllowsPath(boundary, path, indexed: indexed);

  DownloadHistoryNotifier get history => _history();

  /// Whether scanned Library rows count, read per query so a settings
  /// change applies at once.
  bool get includeLibrary => boundary?.includeLocal ?? _includeLibrary();

  static LinkLocalTrack _fromHistory(DownloadHistoryItem item) =>
      LinkLocalTrack(playableFromHistory(item), isrc: item.isrc);

  static LinkLocalTrack _fromLibrary(Map<String, dynamic> row) {
    final item = LocalLibraryItem.fromJson(row);
    return LinkLocalTrack(playableFromLocal(item), isrc: item.isrc);
  }

  @override
  Future<LinkLocalTrack?> recordFor({
    required String id,
    required String source,
  }) async {
    if (source.isNotEmpty) {
      final item = await history.getByFilePathAsync(source);
      if (item != null && allows(item.filePath)) return _fromHistory(item);
    }
    if (!includeLibrary || id.isEmpty) return null;
    final row = await library.getById(id);
    return row == null ||
            !allows(
              row['file_path'] as String? ?? row['filePath'] as String? ?? '',
              indexed: true,
            )
        ? null
        : _fromLibrary(row);
  }

  @override
  Future<List<LinkLocalTrack>> byIsrc(String isrc) async {
    final candidates = {isrc, HistoryDatabase.normalizeIsrc(isrc)}..remove('');
    final found = <LinkLocalTrack>[];
    for (final value in candidates) {
      final item = await history.getByIsrcAsync(value);
      if (item != null && allows(item.filePath)) {
        found.add(_fromHistory(item));
        break;
      }
    }
    if (includeLibrary) {
      for (final value in candidates) {
        final currentScope = boundary;
        final row = currentScope == null
            ? await library.getByIsrc(value)
            : (await library.findExistingBatchScoped([
                LocalLibraryBatchLookupRequest(
                  isrc: value,
                  trackName: '',
                  artistName: '',
                ),
              ], currentScope)).single;
        if (row != null) {
          if (allows(
            row['file_path'] as String? ?? row['filePath'] as String? ?? '',
            indexed: true,
          ))
            found.add(_fromLibrary(row));
          break;
        }
      }
    }
    return found;
  }

  @override
  Future<List<LinkLocalTrack>> byMatchKey(String matchKey) async {
    // Both tables store `normalized title|normalized artist`, and normalizing
    // is idempotent, so the halves of the key look the same row up again.
    final split = matchKey.indexOf('|');
    if (split <= 0) return const [];
    final title = matchKey.substring(0, split);
    final artist = matchKey.substring(split + 1);
    final found = <LinkLocalTrack>[];
    final item = await history.findByTrackAndArtistAsync(title, artist);
    if (item != null && allows(item.filePath)) found.add(_fromHistory(item));
    if (includeLibrary) {
      for (final row in await library.findByTrackAndArtist(title, artist)) {
        if (allows(
          row['file_path'] as String? ?? row['filePath'] as String? ?? '',
          indexed: true,
        ))
          found.add(_fromLibrary(row));
      }
    }
    return found;
  }
}
