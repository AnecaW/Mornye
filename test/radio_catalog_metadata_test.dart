import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/radio_metadata.dart';
import 'package:mornye/services/radio_catalog_metadata.dart';

void main() {
  Track candidate({
    String title = 'Song',
    String artist = 'Artist',
    String album = 'Album',
  }) => Track(
    id: 'catalog',
    name: title,
    artistName: artist,
    albumName: album,
    duration: 180,
    coverUrl: 'https://covers.example/album.jpg',
  );
  test(
    'catalog enrichment requires exact title and artist and deduplicates requests',
    () async {
      var requests = 0;
      final resolver = RadioCatalogMetadata(
        search: (_) async {
          requests++;
          return [
            candidate(title: 'Song (Remix)'),
            candidate(artist: 'Other'),
            candidate(),
          ];
        },
      );
      const track = RadioTrackMetadata(title: 'Song', artist: 'Artist');
      final results = await Future.wait([
        resolver.lookup(track),
        resolver.lookup(track),
      ]);
      expect(requests, 1);
      expect(results.first.album, 'Album');
      expect(
        results.first.artwork.toString(),
        'https://covers.example/album.jpg',
      );
      await resolver.lookup(track);
      expect(requests, 1);
    },
  );
  test('ambiguous albums and unknown artist retain station fallback', () async {
    var requests = 0;
    final resolver = RadioCatalogMetadata(
      search: (_) async {
        requests++;
        return [candidate(), candidate(album: 'Live')];
      },
    );
    expect(await resolver.lookup(const RadioTrackMetadata(title: 'Song')), (
      album: null,
      artwork: null,
    ));
    expect(requests, 0);
    expect(
      await resolver.lookup(
        const RadioTrackMetadata(title: 'Song', artist: 'Artist'),
      ),
      (album: null, artwork: null),
    );
    expect(
      (await resolver.lookup(
        const RadioTrackMetadata(
          title: 'Song',
          artist: 'Artist',
          album: 'Live',
        ),
      )).album,
      'Live',
    );
  });
}
