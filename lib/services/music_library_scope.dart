import 'package:mornye/models/library_database_models.dart';

/// Logical source selection is independent of the storage used by the index.
/// Server rows may live in the same SQL index without belonging to the device.
class MusicLibraryScope {
  MusicLibraryScope({
    required this.deviceEnabled,
    required this.selection,
    required Iterable<String> enabledServers,
  }) : servers = Set.unmodifiable(enabledServers);
  final bool deviceEnabled;
  final String selection;
  final Set<String> servers;
  String? get selectedServer =>
      selection.startsWith('server:') ? selection.substring(7) : null;
  bool get deviceOnly => selection == 'device' && deviceEnabled;
  Set<String> get activeServers {
    if (deviceOnly) return const {};
    final id = selectedServer;
    return id == null
        ? servers
        : servers.contains(id)
        ? {id}
        : const {};
  }

  bool get includeDevice => selectedServer == null;
  bool allowsIndexedPath(String path) {
    final uri = Uri.tryParse(path);
    if (uri?.scheme == 'network') return activeServers.contains(uri!.host);
    return includeDevice &&
        deviceEnabled &&
        uri?.scheme != 'http' &&
        uri?.scheme != 'https';
  }

  String get cacheKey =>
      '$selection/$deviceEnabled/${(servers.toList()..sort()).join(',')}';
  QueueLibraryDbQuery apply(QueueLibraryDbQuery q) => QueueLibraryDbQuery(
    includeSingleTrackAlbums: q.includeSingleTrackAlbums,
    excludeNetwork: q.excludeNetwork,
    albumArtist: q.albumArtist,
    limit: q.limit,
    offset: q.offset,
    filterMode: q.filterMode,
    searchQuery: q.searchQuery,
    source: q.source,
    quality: q.quality,
    format: q.format,
    metadata: q.metadata,
    sortMode: q.sortMode,
    cursor: q.cursor,
    includeLocal: (includeDevice && deviceEnabled) || activeServers.isNotEmpty,
    includeIndexedDevice: includeDevice && deviceEnabled,
    includeDevice: includeDevice,
    deviceOnly: deviceOnly,
    networkScope: activeServers,
  );
  @override
  bool operator ==(Object other) =>
      other is MusicLibraryScope && cacheKey == other.cacheKey;
  @override
  int get hashCode => cacheKey.hashCode;
}
