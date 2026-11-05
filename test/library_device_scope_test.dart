import 'package:mornye/services/library_search.dart';
import 'package:mornye/providers/library_source_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_database.dart';
import 'support/library_paging_fixture.dart';
import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('device-only pagination excludes network rows before LIMIT', () async {
    final db = await SqliteProcessDatabase.open();
    try {
      final store = await createLibraryPagingFixture(db, albumsPerSource: 4);
      for (final column in [
        'storage_mode TEXT',
        'download_tree_uri TEXT',
        'saf_relative_dir TEXT',
        'saf_file_name TEXT',
        'saf_repaired INTEGER',
        'spotify_id TEXT',
        'quality TEXT',
        'replaygain_metadata_scan_version INTEGER',
      ]) {
        await db.execute('ALTER TABLE history_db.history ADD COLUMN $column');
      }
      await db.execute(
        "UPDATE library SET file_path = 'network://server/subsonic/song/id.flac' WHERE id = 'local-0-1'",
      );
      await db.execute(
        "UPDATE history_db.history SET file_path = 'https://server/stream' WHERE id = 'download-0-1'",
      );
      final all = await store.trackPage(
        const QueueLibraryDbQuery(limit: 100, includeSingleTrackAlbums: true),
      );
      final device = await store.trackPage(
        const QueueLibraryDbQuery(
          limit: 100,
          deviceOnly: true,
          includeSingleTrackAlbums: true,
        ),
      );
      expect(device.rows.length, lessThan(all.rows.length));
      expect(
        device.rows.every((row) {
          final item = row['item'] as Map<String, dynamic>;
          return !RegExp(
            r'^(network|https?):',
          ).hasMatch(item['filePath'] as String);
        }),
        isTrue,
      );
      final paged = <Map<String, dynamic>>[];
      for (var offset = 0; ; offset += 2) {
        final page = await store.trackPage(
          QueueLibraryDbQuery(
            limit: 2,
            offset: offset,
            deviceOnly: true,
            includeSingleTrackAlbums: true,
          ),
        );
        paged.addAll(page.rows);
        if (page.rows.length < 2) break;
      }
      expect(paged, device.rows);
    } finally {
      await db.close();
    }
  });
  test(
    'selected indexed network connections never include another source',
    () async {
      final db = await SqliteProcessDatabase.open();
      try {
        final store = await createLibraryPagingFixture(db, albumsPerSource: 4);
        await db.execute(
          "UPDATE library SET file_path='network://one/music/a.flac' WHERE id='local-0-1'",
        );
        await db.execute(
          "UPDATE library SET file_path='network://one-two/music/b.flac' WHERE id='local-0-2'",
        );
        final selected = await store.trackPage(
          const QueueLibraryDbQuery(
            source: 'local',
            networkScope: {'one'},
            includeDevice: false,
            limit: 100,
            includeSingleTrackAlbums: true,
          ),
        );
        expect(selected.rows, hasLength(1));
        expect(
          (selected.rows.single['item'] as Map<String, dynamic>)['filePath'],
          'network://one/music/a.flac',
        );
        final empty = await store.trackPage(
          const QueueLibraryDbQuery(
            source: 'local',
            networkScope: {},
            includeDevice: false,
            includeSingleTrackAlbums: true,
          ),
        );
        expect(empty.rows, isEmpty);
      } finally {
        await db.close();
      }
    },
  );

  test(
    'source selection scopes artists, albums, folders and ranked searches before pagination',
    () async {
      final db = await SqliteProcessDatabase.open();
      try {
        final store = await createLibraryPagingFixture(db, albumsPerSource: 4);
        for (final column in [
          'download_tree_uri TEXT',
          'saf_relative_dir TEXT',
          'saf_file_name TEXT',
        ]) {
          await db.execute('ALTER TABLE history_db.history ADD COLUMN $column');
        }
        await db.execute(
          "UPDATE library SET file_path='network://one/subsonic/song/a.flac' WHERE id='local-0-1'",
        );
        await db.execute(
          "UPDATE library SET file_path='network://two/subsonic/song/b.flac' WHERE id='local-0-2'",
        );
        const base = QueueLibraryDbQuery(
          includeSingleTrackAlbums: true,
          limit: 100,
        );
        final selected = queryForMusicSource(base, serverMusicSource('one'));
        final artists = await store.artistPage(selected);
        expect(artists, hasLength(1));
        expect(artists.single['track_count'], 1);
        final albums = await store.albumPage(selected);
        expect(albums.rows, hasLength(1));
        expect(albums.rows.single['album_key'], startsWith('network://one/'));
        expect(albums.rows.single['track_count'], 1);
        final combined = await store.albumPage(base);
        expect(
          combined.rows.where(
            (row) => (row['album_key'] as String).startsWith('network://'),
          ),
          hasLength(2),
        );
        final folders = await store.directoryEntries(
          includeLocal: true,
          scope: selected,
        );
        expect(folders, hasLength(1));
        expect(folders.single['file_path'], startsWith('network://one/'));
        final search = LibrarySearchStore(
          db,
          historyFts: false,
          localFts: false,
        );
        final hits = await search.search(
          query: 'Song',
          kind: LibrarySearchKind.songs,
          includeLocal: true,
          scope: selected,
          limit: 1,
        );
        expect(hits.single.id, 'local-0-1');
        final second = await search.search(
          query: 'Song',
          kind: LibrarySearchKind.songs,
          includeLocal: true,
          scope: selected,
          limit: 1,
          offset: 1,
        );
        expect(second, isEmpty);
        final removed = queryForMusicSource(base, serverMusicSource('removed'));
        expect((await store.albumPage(removed)).rows, isEmpty);
        expect(await store.artistPage(removed), isEmpty);
        expect(
          await store.directoryEntries(includeLocal: true, scope: removed),
          isEmpty,
        );
        final device = queryForMusicSource(base, deviceMusicSource);
        expect(
          (await store.directoryEntries(
            includeLocal: true,
            scope: device,
          )).every((r) => !(r['file_path'] as String).startsWith('network://')),
          isTrue,
        );
      } finally {
        await db.close();
      }
    },
  );
}
