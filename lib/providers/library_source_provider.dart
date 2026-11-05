import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:mornye/providers/server_favourite_provider.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/logger.dart';

final sourceRefreshTickProvider = StreamProvider.autoDispose<int>(
  (ref) => Stream.periodic(const Duration(minutes: 1), (tick) => tick).where(
    (_) => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  ),
);
const allMusicSources = 'all';
const deviceMusicSource = 'device';
String serverMusicSource(String id) => 'server:$id';
String? musicSourceConnectionId(String source) =>
    source.startsWith('server:') ? source.substring(7) : null;
String musicSourceAccount(NetworkConnection connection) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          connection.id,
          connection.protocol.name,
          connection.address,
          connection.username,
          connection.password,
          connection.subsonicAuth.name,
          connection.apiKey,
        ]),
      ),
    )
    .toString();
final _sourceLog = AppLogger('LibrarySources');
final librarySourceStorageProvider = Provider<NetworkStorageService>(
  (ref) => NetworkStorageService.instance,
);

/// Choices are derived from real connections; there are no user-created profiles.
final librarySourceConnectionsProvider =
    FutureProvider<List<NetworkConnection>>((ref) {
      final storage = ref.watch(librarySourceStorageProvider);
      void changed() => ref.invalidateSelf();
      storage.connectionRevision.addListener(changed);
      ref.onDispose(() => storage.connectionRevision.removeListener(changed));
      return storage.connections();
    });

final selectedLibrarySourceProvider =
    NotifierProvider<LibrarySourceSelection, String>(
      LibrarySourceSelection.new,
    );

class LibrarySourceSelection extends Notifier<String> {
  static const preferenceKey = 'selected_existing_music_source_v1';
  int _generation = 0;
  Future<void> _writes = Future.value();
  @override
  String build() {
    final generation = _generation;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(preferenceKey);
        if (ref.mounted && generation == _generation && saved != null) {
          state = saved;
        }
      } catch (error) {
        _sourceLog.w('Could not restore selected music source: $error');
      }
    }());
    return allMusicSources;
  }

  Future<void> select(String source) {
    _generation++;
    state = source;
    final operation = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(preferenceKey, source);
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _sourceLog.w('Could not save music source: $error');
      },
    );
    return operation;
  }
}

/// A removed server cannot accidentally fall back to displaying device music.
final effectiveLibrarySourceProvider = Provider<String>((ref) {
  final selected = ref.watch(selectedLibrarySourceProvider);
  return selected;
});

QueueLibraryDbQuery queryForMusicSource(
  QueueLibraryDbQuery query,
  String source,
) {
  final connection = musicSourceConnectionId(source);
  return QueueLibraryDbQuery(
    includeSingleTrackAlbums: query.includeSingleTrackAlbums,
    albumArtist: query.albumArtist,
    limit: query.limit,
    offset: query.offset,
    filterMode: query.filterMode,
    searchQuery: query.searchQuery,
    source: query.source,
    quality: query.quality,
    format: query.format,
    metadata: query.metadata,
    sortMode: query.sortMode,
    cursor: query.cursor,
    includeLocal: source == deviceMusicSource ? query.includeLocal : true,
    includeIndexedDevice: query.includeLocal,
    deviceOnly: source == deviceMusicSource,
    networkScope: connection == null ? null : {connection},
    includeDevice: connection == null,
  );
}

String musicSourceLabel(
  String path,
  List<NetworkConnection> connections, {
  String localLabel = 'Local library',
}) {
  final uri = Uri.tryParse(path);
  if (uri?.scheme != 'network') return localLabel;
  for (final connection in connections) {
    if (connection.id == uri!.host) return connection.name;
  }
  return uri!.host;
}

/// Reuses the app's original network indexer and database. It never uploads audio,
/// creates server libraries or changes a local folder's source configuration.
final librarySourceSyncProvider = FutureProvider.autoDispose
    .family<void, String>(_syncExistingMusicSource);

Future<void> _syncExistingMusicSource(Ref ref, String selected) async {
  ref.watch(sourceRefreshTickProvider);
  ref.watch(serverLibraryChangesProvider);
  final connections = await ref.watch(librarySourceConnectionsProvider.future);
  if (selected == allMusicSources) {
    var unavailable = false;
    final ids = connections
        .where((c) => c.protocol == NetworkProtocol.subsonic)
        .map((c) => c.id)
        .toList();
    for (var start = 0; start < ids.length && ref.mounted; start += 4) {
      final end = start + 4 < ids.length ? start + 4 : ids.length;
      await Future.wait(
        ids.sublist(start, end).map((id) async {
          try {
            await ref.watch(
              librarySourceSyncProvider(serverMusicSource(id)).future,
            );
          } catch (_) {
            unavailable = true;
          }
        }),
      );
    }
    if (unavailable) {
      throw StateError(
        'One or more music servers are unavailable. Cached music remains available.',
      );
    }
    return;
  }
  final id = musicSourceConnectionId(selected);
  final servers = connections.where(
    (c) =>
        c.protocol == NetworkProtocol.subsonic &&
        (selected == allMusicSources || c.id == id),
  );
  if (servers.isEmpty) return;
  final library = ref.read(localLibraryProvider.notifier);
  final storage = ref.read(librarySourceStorageProvider);
  final prefs = await SharedPreferences.getInstance();
  for (final connection in servers) {
    if (!ref.mounted) return;
    final path = NetworkStorageService.source(connection.id, '');
    final source = await library.addSource(
      path: path,
      displayName: connection.name,
    );
    if (!ref.mounted) return;
    final fingerprint = musicSourceAccount(connection);
    final ownerKey = 'existing_music_source_owner_${connection.id}';
    final previousOwner = prefs.getString(ownerKey);
    if (previousOwner != null && previousOwner != fingerprint) {
      // Only cached server metadata is retired; never local files or server music.
      await library.removeSource(source.id);
      if (!ref.mounted) return;
    }
    final indexed = previousOwner != null && previousOwner != fingerprint
        ? await library.addSource(path: path, displayName: connection.name)
        : source;
    await prefs.setString(ownerKey, fingerprint);
    final client = storage.openSubsonic(connection, fresh: true);
    String? revision;
    try {
      final status = await client.request('getScanStatus');
      final scan = status['scanStatus'];
      if (scan is Map && scan['scanning'] != true && scan['lastScan'] != null) {
        revision = '${scan['lastScan']}:${scan['count']}';
      }
    } on SubsonicException catch (error) {
      if (error.code == 40 || error.code == 41) {
        throw StateError('Server authentication failed.');
      }
      // Some compatible servers restrict or omit scan status. Read-only indexing still works.
    } catch (_) {
      throw StateError(
        'Server temporarily unavailable. Cached music remains available.',
      );
    } finally {
      client.close();
    }
    if (!ref.mounted) return;
    final revisionKey = 'existing_music_source_scan_${connection.id}';
    final lastSyncKey = 'existing_music_source_sync_${connection.id}';
    final recent =
        DateTime.now().millisecondsSinceEpoch -
            (prefs.getInt(lastSyncKey) ?? 0) <
        const Duration(minutes: 5).inMilliseconds;
    if (indexed.lastScannedAt != null &&
        previousOwner == fingerprint &&
        ((revision != null && prefs.getString(revisionKey) == revision) ||
            (revision == null && recent))) {
      continue;
    }
    while (ref.mounted && ref.read(localLibraryProvider).isScanning) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!ref.mounted) return;
    await library.startSourceScan(indexed.id, waitForCurrentScan: true);
    final saved = await LibraryDatabase.instance.getSourceByPath(path);
    if (saved?.lastScanError != null) {
      throw StateError(
        'The server is temporarily unavailable. Previously synchronized music remains available.',
      );
    }
    if (saved?.lastScannedAt != null) {
      await prefs.setInt(lastSyncKey, DateTime.now().millisecondsSinceEpoch);
      if (revision != null) await prefs.setString(revisionKey, revision);
    }
  }
}
