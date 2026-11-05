import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/library_database.dart';

void main() {
  test('indexed Subsonic tracks keep their server identity for writes', () {
    const source = 'network://one/subsonic/song/c29uZw.flac';
    final local = LocalLibraryItem(
      id: 'network_database_hash',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: source,
      scannedAt: DateTime(2026),
    );
    final match = UnifiedLibraryItem.fromLocalLibrary(local);
    expect(match.toTrack().id, source);
    expect(match.toTrack().source, source);
    final track = collectionTrackForMedia(
      const MediaItem(
        id: 'network_database_hash',
        title: 'Song',
        extras: {'source': source},
      ),
      match,
    );
    expect(track.id, source);
    expect(track.source, source);
    expect(subsonicCollectionSource('network://one/Album/local.flac'), isNull);
  });
  test('a loved song keeps only a cover that outlasts this run', () {
    String? cover(String artUri) => collectionTrackForMedia(
      MediaItem(
        id: 'network://nas/Album/song.flac',
        title: 'Song',
        artUri: Uri.parse(artUri),
      ),
      null,
    ).coverUrl;

    for (final durable in [
      'file:///data/user/0/app/files/covers/a_b.image',
      'https://example.com/cover.jpg',
    ]) {
      expect(cover(durable), durable);
    }
    for (final temporary in [
      'http://127.0.0.1:41234/7f3a',
      'file:///data/user/0/app/cache/network_metadata/a1.jpg',
      Uri.file('${Directory.systemTemp.path}/cover.jpg').toString(),
    ]) {
      expect(cover(temporary), isNull, reason: temporary);
    }
  });
}
