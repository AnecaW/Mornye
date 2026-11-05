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
      '82e2ffdead30cc51c401a100afcbe1760eb7ffdea7ac17e41a7978465082fd4f',
  'filter:no-local':
      '48a448b7535498558b470c1cd83a99c64854b9ff2660d37345bcb44097dc3ff0',
  'filter:no-local-source-local':
      'b7459b17b6ad2874811b9a77a7b493a6d4ea54ad1d4d380adb6cb0e98255c7d3',
  'filter:singles':
      '9beaa4e57e0ca35f9fc91e7be2fce7438e3349def5261f8dba2dd84003a1991c',
  'filter:singles-downloaded':
      '241cafa990d51643e9bad255b6d565bb15c300e3d60986c6d1d25c129b7b2f9a',
  'filter:search':
      '60c1233d99957cfab2108de6f92c5a386765b10cbc7944368729f630f56cf454',
  'filter:album-artist':
      'f18dfe286518c394598656cebf51c09333380f34557f0a2d9fb2111b1e42143f',
  'filter:quality-hires':
      'cca32aea23836b36e2f59e56243203e5efa0735658861cddb9a84bf812278fbb',
  'filter:quality-cd':
      '4c45d0d92eb25b655c1c175ffbd139bca109492a0b18ace4f6629d496252a99b',
  'filter:quality-lossy':
      '8d746a8d00d1b0d8c904385dea0380e7efb21e2b0fa2bb82c267232e45e39164',
  'filter:format-m4a':
      'a519a0c5267f70610dfdc7ddd3facab42c89822d1ec613902f2022b85f18fdf4',
  'filter:format-unknown':
      'd9ca2ea49b2c42a9cf0a2116e71776698c41320a87e0588f5e5d0233be0aa452',
  'filter:metadata-complete':
      '7bd1bfac172a1e7e87e756615fb5c2a6713ced0fd95517d2df064caea11f12f5',
  'filter:metadata-missing-any':
      'bf8b98670df3405a5ebdbcf4bae9ad60c5375e15107845be2ec657d6fe19de8c',
  'filter:metadata-missing-year':
      '45a7f6ff4f8c128a3f86f7a49c30397dffcef6467175ea0c3cb15ec9bd96fb8f',
  'filter:metadata-missing-genre':
      'a30d6c45f7fd537e5632b3c0764f0db74ce45a3c35fc1a495a09e5a445dd1a6c',
  'filter:metadata-missing-album-artist':
      'b599f879ab759f8acdb58fd2ce2dc75049c4ee3b2c9234c9a69cd8affecacc9d',
  'filter:metadata-missing-track-number':
      'ea9cb017ff0c157bbea77be8d866530781b2205b06453cf989f45eb9368090b1',
  'filter:metadata-missing-disc-number':
      'baf0c9eae7a6566a5a48f32f4dac142232a38bca36a3fe6c7664b22b7ad20df7',
  'filter:metadata-missing-artist':
      '738a70c7a45f7c670d7026c9d0eef56f774a5d6467ab03125a2103c6a4c3a5f8',
  'filter:metadata-incorrect-isrc-format':
      'acfcc1d3f3865bcc2ccbd1c0e11e01bd9edca7873c60c17d1890a0dd069ada5a',
  'filter:metadata-missing-isrc':
      '2bfdc0bd8ae8709af57e47477ee325870ebb9ec3607406ccc213fa91c712ce96',
  'filter:metadata-missing-label':
      '03af2187ee60cd1796342743e9011473f4d741316dffa81b78ae37629a6f894f',
  'filter:metadata-missing-lyrics':
      '251f4cf8d7bbf185e2ec3ccd5954a17ac8a220b1df75e46885dafae5687b43fd',
  'filter:metadata-has-replaygain':
      '804780486d6f7b06b356e8311eee173279966582325e02a6b1f72f39f369753f',
  'filter:metadata-missing-replaygain':
      '1f87b0e36f655582d20df00a837ee25d038727284028e95a30d022cfd1e6804b',
  'filter:metadata-incomplete-album':
      'e8fe1891c98d11690b049add9ef02a12fb34677a861d5e80d88dcfe309dc8881',
  'filter:metadata-unknown-album-completeness':
      '14f68a6fceff8e9aa205d5d558caddad2ef26f937e99c82f25a0f700081a8214',
  'filter:metadata-unknown-metadata':
      'c1864ae48b998a6fd85b49f4344ab1d040df18a2c2c83e37da74753185f9498e',
  'filter:single-track-albums':
      '5dac4d1a1e9e9ceaaec00d150f9e74449c0164018f1559660fddbc525cbef98f',
  'filter:single-track-albums-incomplete':
      'e8fe1891c98d11690b049add9ef02a12fb34677a861d5e80d88dcfe309dc8881',
  'filter:combined':
      '63064c341847e9ff8f2c9647f7933bcae4a330cd45e70db0e5aa8db3afa565ac',
  'filter:combined-local':
      '37919fe08108acb2d36a119b343bb0a9bcd2d351ae73b59fbe61b5aaa4527e56',
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
