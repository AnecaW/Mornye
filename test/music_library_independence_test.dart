import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_source_scope.dart';
import 'package:mornye/services/music_library_scope.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'support/sqlite_process_database.dart';
import 'support/library_paging_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;
  setUp(() async {
    db = await SqliteProcessDatabase.open();
    store = await createLibraryPagingFixture(db, albumsPerSource: 0);
    final historyColumns = (await db.rawQuery(
      'PRAGMA history_db.table_info(history)',
    )).map((r) => r['name']).toSet();
    for (final column in [
      'storage_mode',
      'download_tree_uri',
      'saf_file_name',
      'saf_relative_dir',
      'saf_repaired',
      'quality',
      'spotify_id',
      'replaygain_metadata_scan_version',
    ]) {
      if (!historyColumns.contains(column))
        await db.execute('ALTER TABLE history_db.history ADD COLUMN $column');
    }
    for (final id in ['device', 'nas', 'other']) {
      final path = id == 'device'
          ? '/music/device.flac'
          : 'network://$id/subsonic/song/shared.flac';
      await db.insert('library_sources', {
        'id': id,
        'path': id == 'device' ? '/music' : 'network://$id/',
        'display_name': id,
        'enabled': 1,
        'available': 1,
      });
      await db.insert('library', {
        'id': '$id:song',
        'source_id': id,
        'file_path': path,
        'track_name': 'Same song',
        'artist_name': 'Artist',
        'album_name': 'Same album',
        'album_key': 'same|artist',
        'match_key': 'same song|artist',
        'isrc': 'SHARED',
        'scanned_at': '2026-11-06',
        'duration': 180,
      });
    }
  });
  tearDown(() => db.close());
  final cases = [
    (
      name: 'only local',
      local: true,
      servers: <String>{},
      selected: 'all',
      expected: {'device:song'},
    ),
    (
      name: 'only Navidrome',
      local: false,
      servers: {'nas'},
      selected: 'all',
      expected: {'nas:song'},
    ),
    (
      name: 'device and NAS',
      local: true,
      servers: {'nas'},
      selected: 'all',
      expected: {'device:song', 'nas:song'},
    ),
    (
      name: 'local off while NAS selected',
      local: false,
      servers: {'nas'},
      selected: 'server:nas',
      expected: {'nas:song'},
    ),
    (
      name: 'NAS disabled while device selected',
      local: true,
      servers: <String>{},
      selected: 'device',
      expected: {'device:song'},
    ),
    (
      name: 'combined independent sources',
      local: true,
      servers: {'nas', 'other'},
      selected: 'all',
      expected: {'device:song', 'nas:song', 'other:song'},
    ),
    (
      name: 'specific server ignores identically named other song',
      local: false,
      servers: {'nas', 'other'},
      selected: 'server:other',
      expected: {'other:song'},
    ),
  ];
  for (final c in cases) {
    test('actual SQLite source boundaries: ${c.name}', () async {
      final scope = MusicLibraryScope(
        deviceEnabled: c.local,
        selection: c.selected,
        enabledServers: c.servers,
      );
      final q = scope.apply(const QueueLibraryDbQuery(limit: 100));
      final page = await store.trackPage(q);
      expect(
        page.rows.map((r) => (r['item'] as Map)['id']).toSet(),
        c.expected,
      );
      expect((await store.counts(q)).allTrackCount, c.expected.length);
      final mixRows = await store.mixSongs(
        includeLocal: q.includeLocal,
        limit: 100,
        offset: 0,
        scope: q,
      );
      expect(mixRows.map((r) => r['id']).toSet(), c.expected);

      final where = <String>[], args = <Object?>[];
      appendLibrarySourceScope(where, args, q, 'file_path', indexed: true);
      final matches = <String, Map<String, dynamic>>{};
      await sqlite.loadRowsByColumn(
        db,
        table: 'library_visible',
        column: 'id',
        rawValues: ['device:song', 'nas:song', 'other:song'],
        destination: matches,
        mapRow: (row) => Map<String, dynamic>.from(row),
        extraWhere: where.join(' AND '),
        extraWhereArgs: args,
      );
      expect(matches.keys.toSet(), c.expected);
      expect(
        (await db.rawQuery('SELECT COUNT(*) AS n FROM library WHERE id != ?', [
          'hidden',
        ])).single['n'],
        3,
      );
    });
  }
  test(
    'offline and reconnect retain the same server identities without rescanning',
    () async {
      final q = MusicLibraryScope(
        deviceEnabled: false,
        selection: 'server:nas',
        enabledServers: {'nas'},
      ).apply(const QueueLibraryDbQuery());
      await db.update(
        'library_sources',
        {'available': 0},
        where: 'id = ?',
        whereArgs: ['nas'],
      );
      expect((await store.trackPage(q)).rows, isEmpty);
      expect(
        await db.rawQuery('SELECT id FROM library WHERE source_id = ?', [
          'nas',
        ]),
        [
          {'id': 'nas:song'},
        ],
      );
      await db.update(
        'library_sources',
        {'available': 1},
        where: 'id = ?',
        whereArgs: ['nas'],
      );
      expect(
        (await store.trackPage(q)).rows.map((r) => (r['item'] as Map)['id']),
        ['nas:song'],
      );
    },
  );
}
