import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

// Whitespace outside literals is insignificant, and no literal in the queue
// SQL contains a whitespace run.
String _normalized(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Records every query and returns no rows, so the generated SQL can be pinned
/// without a database.
class _RecordingDatabase implements Database {
  final queries = <String>[];

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    queries.add('${_normalized(sql)}\n${jsonEncode(arguments)}');
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _sortModes = [
  'latest',
  'oldest',
  'a-z',
  'z-a',
  'artist-asc',
  'artist-desc',
  'album-asc',
  'album-desc',
  'release-oldest',
  'release-newest',
  'genre-asc',
  'genre-desc',
  'size-asc',
  'size-desc',
  'unknown-sort',
];

const _cursor4 = QueueLibraryDbCursor(['c0', 'c1', 2, 'c3']);
const _cursor5 = QueueLibraryDbCursor(['c0', 1, 'c2', 'c3', 'c4']);

final _filters =
    <String, QueueLibraryDbQuery Function(String, QueueLibraryDbCursor?)>{
      'default': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor),
      'source-downloaded': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        source: 'downloaded',
      ),
      'source-local': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, source: 'local'),
      'source-other': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, source: 'other'),
      'no-local': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeLocal: false,
      ),
      'no-local-source-local': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeLocal: false,
        source: 'local',
      ),
      'singles': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        filterMode: 'singles',
      ),
      'singles-downloaded': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        filterMode: 'singles',
        source: 'downloaded',
      ),
      'search': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        searchQuery: ' Hello_50% \\ World ',
      ),
      'album-artist': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        albumArtist: 'Some Artist',
      ),
      'quality-hires': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        quality: ' HiRes ',
      ),
      'quality-cd': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, quality: 'cd'),
      'quality-lossy': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, quality: 'lossy'),
      'format-m4a': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, format: 'M4A'),
      'format-unknown': (sort, cursor) =>
          QueueLibraryDbQuery(sortMode: sort, cursor: cursor, format: 'x_y%'),
      for (final metadata in [
        'complete',
        'missing-any',
        'missing-year',
        'missing-genre',
        'missing-album-artist',
        'missing-track-number',
        'missing-disc-number',
        'missing-artist',
        'incorrect-isrc-format',
        'missing-isrc',
        'missing-label',
        'missing-lyrics',
        'has-replaygain',
        'missing-replaygain',
        'incomplete-album',
        'unknown-album-completeness',
        'unknown-metadata',
      ])
        'metadata-$metadata': (sort, cursor) => QueueLibraryDbQuery(
          sortMode: sort,
          cursor: cursor,
          metadata: metadata,
        ),
      'single-track-albums': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeSingleTrackAlbums: true,
      ),
      'single-track-albums-incomplete': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        includeSingleTrackAlbums: true,
        metadata: 'incomplete-album',
      ),
      'combined': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        source: 'downloaded',
        filterMode: 'singles',
        searchQuery: 'hello',
        albumArtist: 'Some Artist',
        quality: 'hires',
        format: 'flac',
        metadata: 'missing-genre',
        limit: 7,
        offset: 21,
      ),
      'combined-local': (sort, cursor) => QueueLibraryDbQuery(
        sortMode: sort,
        cursor: cursor,
        source: 'local',
        filterMode: 'singles',
        searchQuery: 'hello',
        albumArtist: 'Some Artist',
        quality: 'cd',
        format: 'ogg',
        metadata: 'unknown-album-completeness',
        limit: 7,
        offset: 21,
      ),
    };

/// SHA-256 of the normalized SQL and bound arguments of every query each case
/// issues. Captured from the reference implementation; a mismatch means the
/// Library order, filter or paging SQL changed.
const _expectedDigests = <String, String>{
  'sort:latest':
      '74d9b9f49e261c35330f579e4d8a735fe41afc66d54fa249c20c3d88ccf9775c',
  'sort:oldest':
      '096908156c9fb210224c902a0590efd3bf2be581e6f080a034ac90044911f9a8',
  'sort:a-z':
      'ea97ab7c51c3c5b29fae3622ecffea422e8154d625ed0a6f5f492ca4d481f75a',
  'sort:z-a':
      '3bcf9dc8831c620e24a2bb60a4fa4282564f2dda62f27e81d91cbc7cf4425d99',
  'sort:artist-asc':
      'c94772ce29d4143f18f1ca251228716bc1f34000b278a2269dbf6f73785faddf',
  'sort:artist-desc':
      '36c2ad12ac4161bd3df43d7b4e654248317d893792f8a20819c698659732e5da',
  'sort:album-asc':
      '56d092f727d2ad1ae008964567ac38532b243c13aecd50c19c0cee370d78e28c',
  'sort:album-desc':
      '8d0643041435be87322626009084889bf1ec46d2c137891f017171b8ac68432d',
  'sort:release-oldest':
      '243b0abad86982a5a9332799dbfc484d24583e6babaf710574732cd03cee8cf3',
  'sort:release-newest':
      '9c534de3e4d3124bfa706d7773c0f2828b4a9cb92c01f49452ae46cce802bd79',
  'sort:genre-asc':
      '633f28790317b897585bc8783c6ae514c0539aa793d1a1e238fd4483f522e97b',
  'sort:genre-desc':
      '42970a0fc3162f067c1db1b1d33afc37c12542d3e879a978a02a0833e31d3f30',
  'sort:size-asc':
      'a30ae7a628e7b56a65af7c044dc895ab58c17dbe4d715b728a8456b3d55d7b32',
  'sort:size-desc':
      '27ab656b67918221e48516536ff5e593607581569a5931e3f9487ea82cd7c841',
  'sort:unknown-sort':
      '74d9b9f49e261c35330f579e4d8a735fe41afc66d54fa249c20c3d88ccf9775c',
  'filter:default':
      '11061c5ed481be84131bd4340f5623eabdce4563c9307bdc04f771f9bd59f975',
  'filter:source-downloaded':
      '80b7f38386a6a309e2ebe3db8e32f0764d12d6790d49063b51286bfe1134032b',
  'filter:source-local':
      'ff58c45f4195b1a321156663e278c293bd82e0fdc187c625d7eadeee3e72d5de',
  'filter:source-other':
      '777494d5fe4bedd4ee3835aeb3a8267d3418eedaa8bfd0b05dc45e346c24708f',
  'filter:no-local':
      '80b7f38386a6a309e2ebe3db8e32f0764d12d6790d49063b51286bfe1134032b',
  'filter:no-local-source-local':
      'b1a875e48c05f87df701cc0ed14f7e036b003f6d35394ac03666092eed5443c3',
  'filter:singles':
      '32440ab25277f95a3a75353c76e0eddfb5ad7b285ddd4e1d964dc259499c67f0',
  'filter:singles-downloaded':
      '104dcb6ce1592c814d81f00676fbbe265c6b3c770f53d6d09721627d7b783de2',
  'filter:search':
      '9ade29e5aee19a0a8ac0e669a539533d1ea5149d116dc5e3ab06442461f676d7',
  'filter:album-artist':
      'd3a97fe1fb8e4c56ad0d6157818db95467e8fa0b040375e9b5a601d4f7e58f5f',
  'filter:quality-hires':
      'a0af06fb8b12b91e094668377fad92406d3112fe75da82b1c1e4950dade6ad11',
  'filter:quality-cd':
      '32845120f54d39dc1bbea48d845f492277a37e048b72cb8d8a3bf0b9a6bc6aef',
  'filter:quality-lossy':
      '5f511e0f086c831bd3edfdc9b3b8dc1d68dec16205004524d7a9056a3c039acd',
  'filter:format-m4a':
      '199d5fcaa8d1386e909e98c5a3d52866ed77710d560c85d001fff41ed94d4752',
  'filter:format-unknown':
      '7109b52527a24b4f9407491e24e5be40da03d646a595cf0ab161533b93f684ef',
  'filter:metadata-complete':
      '384ad5ca2ca3ba52433c7c371cd2e504795e3ad325305599742e9459e183feac',
  'filter:metadata-missing-any':
      'e404a878ef81cd74be26a19c42ba6214c8ef5d2301a67277122ea46359ec124c',
  'filter:metadata-missing-year':
      'daed66768478094f8f6ad54c798ffec1540381556b3b2964a7708fea24522454',
  'filter:metadata-missing-genre':
      '542a3c8d11791099e91a6c5ebdad7466eb13a785ce0739ec6eb9c8469b9c0cd8',
  'filter:metadata-missing-album-artist':
      'f7b8757687005b3e5505cb3a2a789c3683db078b4393b4c90f2949d76dfd32c9',
  'filter:metadata-missing-track-number':
      '30002c2a3ed48d676dfd27fa7fbda8f1b314acae8cd6ba5b4944a59d825d03d0',
  'filter:metadata-missing-disc-number':
      '65b165280856e98f9f53e539919e82d3f91db7e2e27b39f2c37b1035ab8d251c',
  'filter:metadata-missing-artist':
      '628c78f7747df98f27a6f1d1c9f7b679f07f20f0ac2ef0dfe307a1d50b820e3f',
  'filter:metadata-incorrect-isrc-format':
      'f7a9689e1f6df0a3d4d4f0cc22f4b1e170c73b99044abb090a8f95ce8ee79c8a',
  'filter:metadata-missing-isrc':
      '5746b0591a7929f772504ce73b79b0bf6b3f8f98db1c50a9da4e2a505833b8d9',
  'filter:metadata-missing-label':
      'e802064c487006f20332402cb957f4b0a13e61b9f84ee10c81e65a6617a1348b',
  'filter:metadata-missing-lyrics':
      'b9a4544934c9d40e82a76cfb91d834d82641bc83fa4abf1f369577445efea2c9',
  'filter:metadata-has-replaygain':
      '70ca2a1ddfcbd1c48f2354b28ed80cc257f6c86ee8a3ec16d99b9fab696bb7b7',
  'filter:metadata-missing-replaygain':
      '770dc603a0b5f55322c702b1cc0f9df2d70379f233d2122843af27a4d42cce4a',
  'filter:metadata-incomplete-album':
      '45df41d9de4b2c84372a1a6fde137514a9bca987432d844fb09bb56fd9f85f20',
  'filter:metadata-unknown-album-completeness':
      '0b833b4cb3e86fa174e1f7e8171a627be9ddf3b1887bf801fef8a97b94384717',
  'filter:metadata-unknown-metadata':
      'a92537cce474b9d1cae81f0daecdd7a54d6ac8d141a5faf7136caf202d55ef72',
  'filter:single-track-albums':
      'd808d97431514b2a61a0ff0e8073885f8363601075303599ca18e9a816d46941',
  'filter:single-track-albums-incomplete':
      '45df41d9de4b2c84372a1a6fde137514a9bca987432d844fb09bb56fd9f85f20',
  'filter:combined':
      '0aae63d5b2f38384a233d79a4f648d5846e795ee149fb87965c665012cfba613',
  'filter:combined-local':
      '9f9d40a44066be32452493cbf25e02c77c84f5f6b251961d808169539b2ab2fa',
};

/// Each shadow check of the snapshot SQL, with the row check it replaces.
final _rowChecks = {
  for (final includeLocal in [true, false])
    _normalized(
      albumInventorySql(includeLocal: includeLocal, shadowSnapshot: true),
    ): _normalized(
      albumInventorySql(includeLocal: includeLocal),
    ),
  for (final alias in ['l', 'candidate'])
    _normalized(sqlite.libraryNotShadowedSql(alias, snapshot: true)):
        _normalized(sqlite.libraryNotShadowedSql(alias)),
};
final _snapshotSql = <String>[];

/// Also issues the shadow-snapshot SQL, which must equal the pinned SQL once
/// each shadow check is put back to its row check.
Future<String> _digest(
  Future<void> Function(LibraryQueueStore store) issue,
) async {
  final queries = <String>[];
  for (final fts in [false, true]) {
    final db = _RecordingDatabase();
    await issue(LibraryQueueStore(db, historyFts: fts, localFts: fts));
    queries.addAll(db.queries);
    final snapshot = _RecordingDatabase();
    await issue(
      LibraryQueueStore(
        snapshot,
        historyFts: fts,
        localFts: fts,
        shadowSnapshot: true,
      ),
    );
    _snapshotSql.addAll(snapshot.queries);
    expect([
      for (final sql in snapshot.queries)
        _rowChecks.entries.fold(
          sql,
          (sql, check) => sql.replaceAll(check.key, check.value),
        ),
    ], db.queries);
  }
  return sha256.convert(utf8.encode(queries.join('\n---\n'))).toString();
}

void main() {
  test(
    'queue SQL is pinned for every sort mode, filter and page shape',
    () async {
      final actual = <String, String>{};
      for (final sort in _sortModes) {
        actual['sort:$sort'] = await _digest((store) async {
          for (final cursor in [null, _cursor4, _cursor5]) {
            final request = QueueLibraryDbQuery(sortMode: sort, cursor: cursor);
            await store.trackPage(request);
            await store.albumPage(request);
          }
          final paged = QueueLibraryDbQuery(
            sortMode: sort,
            limit: 20,
            offset: 40,
          );
          await store.trackPage(paged);
          await store.albumPage(paged);
        });
      }
      for (final MapEntry(key: name, value: build) in _filters.entries) {
        actual['filter:$name'] = await _digest((store) async {
          for (final (sort, cursor) in [
            ('latest', null),
            ('latest', _cursor4),
            ('size-desc', null),
            ('size-desc', _cursor5),
            ('album-asc', _cursor4),
          ]) {
            final request = build(sort, cursor);
            await store.trackPage(request);
            await store.albumPage(request);
            await store.counts(request);
            await store.artistPage(request);
          }
        });
      }
      final mismatches = [
        for (final MapEntry(:key, :value) in actual.entries)
          if (_expectedDigests[key] != value) "    '$key': '$value',",
      ];
      expect(
        mismatches,
        isEmpty,
        reason: 'Changed SQL digests:\n${mismatches.join('\n')}',
      );
      expect(_expectedDigests.keys, unorderedEquals(actual.keys));
      // No snapshot query probes a row's path keys against History.
      expect(
        _snapshotSql.where((sql) => sql.contains('history_path_keys')),
        isEmpty,
      );
      expect(
        _snapshotSql.where((sql) => sql.contains('library_shadowed')),
        isNotEmpty,
      );
    },
  );
}
