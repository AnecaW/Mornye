import 'package:audio_service/audio_service.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discord_artwork_resolver.dart';
import 'package:mornye/services/metadata_autofill_service.dart';
import 'package:mornye/services/radio_metadata.dart';

typedef RadioCatalogDetails = ({String? album, Uri? artwork});

/// Uses Mornye's configured catalog providers, with the existing strict artwork
/// matcher. A radio title is never enough to select the first search result.
class RadioCatalogMetadata {
  RadioCatalogMetadata({Future<List<Track>> Function(String)? search})
    : _search = search ?? _searchProviders;
  final Future<List<Track>> Function(String) _search;
  final _pending = <String, Future<RadioCatalogDetails>>{};
  final _cache = <String, ({DateTime expires, RadioCatalogDetails details})>{};
  static String _normalized(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static Future<List<Track>> _searchProviders(String query) async => [
    for (final row in await MetadataAutofillService().search(query))
      Track.fromBackendMap(row),
  ];
  Future<RadioCatalogDetails> lookup(RadioTrackMetadata track) async {
    if (track.title.isEmpty || track.artist.isEmpty)
      return (album: null, artwork: null);
    final cached = _cache[track.key];
    if (cached != null && cached.expires.isAfter(DateTime.now()))
      return cached.details;
    if (_pending[track.key] case final request?) return request;
    final operation = _lookup(track);
    _pending[track.key] = operation;
    try {
      final details = await operation;
      _cache.remove(track.key);
      while (_cache.length >= 64) {
        _cache.remove(_cache.keys.first);
      }
      _cache[track.key] = (
        expires: DateTime.now().add(const Duration(minutes: 5)),
        details: details,
      );
      return details;
    } finally {
      _pending.remove(track.key);
    }
  }

  Future<RadioCatalogDetails> _lookup(RadioTrackMetadata track) async {
    try {
      final candidates = await _search(
        '${track.title} ${track.artist}',
      ).timeout(const Duration(seconds: 8));
      final exact = candidates
          .where(
            (candidate) =>
                _normalized(candidate.name) == _normalized(track.title) &&
                _normalized(candidate.artistName) ==
                    _normalized(track.artist) &&
                (track.album.isEmpty ||
                    _normalized(candidate.albumName) ==
                        _normalized(track.album)),
          )
          .toList();
      if (exact.isEmpty) return (album: null, artwork: null);
      // Multiple releases with different album names are ambiguous. Retain the
      // station fallback unless the stream itself identifies that album.
      if (track.album.isEmpty &&
          exact.map((c) => _normalized(c.albumName)).toSet().length > 1) {
        return (album: null, artwork: null);
      }
      final artwork = discordMatchedArtwork(
        MediaItem(
          id: track.key,
          title: track.title,
          artist: track.artist,
          album: track.album,
        ),
        exact,
      );
      return (
        album: exact.first.albumName.isEmpty ? null : exact.first.albumName,
        artwork: artwork == null ? null : Uri.tryParse(artwork),
      );
    } catch (_) {
      return (album: null, artwork: null);
    }
  }
}
