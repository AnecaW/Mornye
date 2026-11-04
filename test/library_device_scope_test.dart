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
}
