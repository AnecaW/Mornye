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
      'a206f0f7f43cea08de0c7d2e923016778db6296e0a3c61e1cf4fbf688ee6b62a',
  'sort:oldest':
      'f11c330252a190506e700565487a2821d1f959fcb6b307a287103cfa619f5ace',
  'sort:a-z':
      '2b29701884a6448e2aceb2ce10b5d3bb0391b39242ed9d6fcbe354aaa56bdbd4',
  'sort:z-a':
      'e4029325048721e44282bbfdd60b8266f68ac0360fd2f559c56f325d541e2166',
  'sort:artist-asc':
      '9132db0deaa8e44160afd6af92b17507806b3f11a2af6866911580f6d566a8ce',
  'sort:artist-desc':
      '2a58e985a310c2a8d45473fd55e153eead9e0585637d457295f758a9aa6f6122',
  'sort:album-asc':
      '1027d14f91daa93fb6e799ab95ea2fdad6fd5dfa1d9fe44a29eaf6908123a6ab',
  'sort:album-desc':
      '263d5823bdb38e4b7148f7c5a9d79fc114f52f37490aaa2bcc503621b73121ec',
  'sort:release-oldest':
      '4cebb6b820dcd0f2bce240b087bcf548021fc4800a7a07619c6db0c3dbd19c0e',
  'sort:release-newest':
      '177f290b60a5127b9feb73f3b989389301b2f2fee5df151e94cffbf5b95cd7a8',
  'sort:genre-asc':
      '573f233a533f8dff872945f5f258e3f5490b97072ea302d2c5bc17cde35b2f80',
  'sort:genre-desc':
      '9617522cfad212c260c7004cc7c919017ebaada6702009b80758cf329ac5d561',
  'sort:size-asc':
      '093bc564a13225d5ef07f0fb031564501b97cf620e9e8eff1c5d02b2cd8d1d2d',
  'sort:size-desc':
      'a2ad4ebef319d317ecabc81a6ab1c7a13cce8d04153d93c5a31f3948955ac31f',
  'sort:unknown-sort':
      'a206f0f7f43cea08de0c7d2e923016778db6296e0a3c61e1cf4fbf688ee6b62a',
  'filter:default':
      'b97c9e46d08c8ef7bcaa5c4281b86ed164f2cbf5baef184c042993e815cdf851',
  'filter:source-downloaded':
      '48a448b7535498558b470c1cd83a99c64854b9ff2660d37345bcb44097dc3ff0',
  'filter:source-local':
      '1a33c62fa1f64f930b221e1d675ff0428153d6840521850c30f2a693ec64e995',
  'filter:source-other':
      'e2ce1acf765e55e8e515cca6eda14280960c4859cc98c4baed033ef66dbc6db8',
  'filter:no-local':
      '48a448b7535498558b470c1cd83a99c64854b9ff2660d37345bcb44097dc3ff0',
  'filter:no-local-source-local':
      'b7459b17b6ad2874811b9a77a7b493a6d4ea54ad1d4d380adb6cb0e98255c7d3',
  'filter:singles':
      '9beaa4e57e0ca35f9fc91e7be2fce7438e3349def5261f8dba2dd84003a1991c',
  'filter:singles-downloaded':
      '241cafa990d51643e9bad255b6d565bb15c300e3d60986c6d1d25c129b7b2f9a',
  'filter:search':
      '5c92d21dac18826dd73ac4589bd2e0c641cbf73a5a9196a82f5d085304e726c0',
  'filter:album-artist':
      '2c6dc6e47b6f5ee1dbd95cf027e0927b7a99de905b1ff42a5fa913ebea70874e',
  'filter:quality-hires':
      'c6cd09c20e2461cbfb4a832bd032432763077c18628e2281f333098004f536a5',
  'filter:quality-cd':
      '52577a1a6c7ee0a8a1b1abc46c2b9fc755e2807ce77ae79af19df57906d0afc7',
  'filter:quality-lossy':
      '4f6d937f821b997200cac561298b002bb9303badb8da9971ac21e3d165a424e1',
  'filter:format-m4a':
      '8ca6753730f5709af4968950d9af9d6ee956181a2c4e49a5263f539d8ed465a4',
  'filter:format-unknown':
      'af291526cbebcd91b0aaa78771e9e23daf921e2d870ad44c479ae33b6f6e382e',
  'filter:metadata-complete':
      '8f31970109d8ef2abfe28113dba42c15c081759841e336ccb6ea046bde9fcbf1',
  'filter:metadata-missing-any':
      'a19d32cd3b743fe6f599d823a3aea9888b7ced3445c0555b14c0a2ba63b197f9',
  'filter:metadata-missing-year':
      'c74ad17f5ee854d7eb7bea1eec28cf04a9be7434c56fd27037ff7ee25ecbdac5',
  'filter:metadata-missing-genre':
      '6c10becba609f458e48d5aaba70f2e92d06783ce92af59512f956510b7643325',
  'filter:metadata-missing-album-artist':
      '54c262989e54a0a838c7577f3aac9c6777c6991724f25f866b7fc35b9d38b853',
  'filter:metadata-missing-track-number':
      'ad0164c2c9c65f956af8730a85370fbf5bd936d28c90279b29ca852adac6b131',
  'filter:metadata-missing-disc-number':
      'f6b1cf191dab5d78271d8a8a66016c02c4d667d199c2d8b485cc5c14d4c5f103',
  'filter:metadata-missing-artist':
      '03feb009720f0eb3087a96fc0632195131ab5e03735cf02f7df49d9bbe59b120',
  'filter:metadata-incorrect-isrc-format':
      'f7b54a1d842e792b485f88b7567834d8a0c7df71120f7384427ab5e496972a0e',
  'filter:metadata-missing-isrc':
      '72b35137192582b3b89959931b633da756af8d9f6099d018461043c727cda1d9',
  'filter:metadata-missing-label':
      'ecf95ebe94fbf4086e30893fa91eb59c70bcef2256e621f46667bf112cee5107',
  'filter:metadata-missing-lyrics':
      'ce31c70b2eadc138bc664fb42afc8180436953234890c288653d83a43ecf5d5f',
  'filter:metadata-has-replaygain':
      'e755265399bae502fdccfc3a478794a266a48e4915e98ff609dac151aa7fe8b9',
  'filter:metadata-missing-replaygain':
      'ea302e8606d23e76752e39330bd055b9d50023109ff106420069d62e6f6defe1',
  'filter:metadata-incomplete-album':
      'd8e07caef7d4a1be4ecadd14293048cbbaf188e6653cf492b78fc8a8312f5763',
  'filter:metadata-unknown-album-completeness':
      '30cd64aeacab92ac61ba01bbadd21eebd57dda506a1983c5c8c51dc228b4af64',
  'filter:metadata-unknown-metadata':
      '7fa34f23b10abf1bc5c12b32ea45b635245c6905927d6e05c99956e8cc36a8d3',
  'filter:single-track-albums':
      '5dac4d1a1e9e9ceaaec00d150f9e74449c0164018f1559660fddbc525cbef98f',
  'filter:single-track-albums-incomplete':
      'd8e07caef7d4a1be4ecadd14293048cbbaf188e6653cf492b78fc8a8312f5763',
  'filter:combined':
      '63064c341847e9ff8f2c9647f7933bcae4a330cd45e70db0e5aa8db3afa565ac',
  'filter:combined-local':
      '6e082c1055d348e02a1e8965830414770d0812fb4461abd1f0cb1ecfadc2ae90',
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
