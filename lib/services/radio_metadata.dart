import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Only information actually supplied by the broadcast. A missing artist stays
/// unknown; the station name is never passed to a music lookup as an artist.
class RadioTrackMetadata {
  const RadioTrackMetadata({
    required this.title,
    this.artist = '',
    this.album = '',
  });
  final String title, artist, album;
  String get key => jsonEncode([title, artist, album]);
  factory RadioTrackMetadata.fromFields(Map<String, String> fields) {
    final raw = fields['streamTitle'];
    if (raw != null) {
      final separator = raw.indexOf(' - ');
      return RadioTrackMetadata(
        title: separator < 0 ? raw.trim() : raw.substring(separator + 3).trim(),
        artist: separator < 0 ? '' : raw.substring(0, separator).trim(),
      );
    }
    return RadioTrackMetadata(
      title: fields['title'] ?? '',
      artist: fields['artist'] ?? '',
      album: fields['album'] ?? '',
    );
  }
}

Map<String, String> parseIcyMetadata(List<int> bytes) {
  final value = utf8
      .decode(bytes, allowMalformed: true)
      .replaceAll('\u0000', '');
  final match = RegExp(
    r"(?:^|;)\s*StreamTitle='(.*?)';",
    dotAll: true,
  ).firstMatch(value);
  return match == null ? const {} : {'streamTitle': match.group(1)!.trim()};
}

/// One cancellable, bounded ICY inspection. The audio player owns its independent
/// progressive stream. No full song or album is downloaded by metadata polling.
Future<Map<String, String>> readIcyMetadata(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
  request.headers.set('Icy-MetaData', '1');
  request.maxRedirects = 5;
  final response = await request.close().timeout(const Duration(seconds: 5));
  final interval = int.tryParse(response.headers.value('icy-metaint') ?? '');
  if (response.statusCode != 200 ||
      interval == null ||
      interval <= 0 ||
      interval > 256 * 1024) {
    await response.listen((_) {}).cancel();
    return const {};
  }
  var remainingAudio = interval, metadataLength = -1, seen = 0;
  final metadata = <int>[];
  await for (final chunk in response.timeout(const Duration(seconds: 5))) {
    for (final byte in chunk) {
      if (++seen > 1024 * 1024) return const {};
      if (remainingAudio > 0) {
        remainingAudio--;
        continue;
      }
      if (metadataLength < 0) {
        metadataLength = byte * 16;
        if (metadataLength == 0) {
          remainingAudio = interval;
          metadataLength = -1;
        }
        continue;
      }
      metadata.add(byte);
      if (metadata.length == metadataLength) return parseIcyMetadata(metadata);
    }
  }
  return const {};
}

/// Native timed metadata is sampled locally. ICY is inspected at most once per
/// 15 seconds; all outstanding work is closed on station/track replacement.
class RadioMetadataMonitor {
  RadioMetadataMonitor({
    required this.source,
    required this.native,
    required this.onChanged,
  });
  final String source;
  final Future<Map<String, String>> Function() native;
  final void Function(RadioTrackMetadata) onChanged;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  Timer? _timer;
  bool _closed = false;
  DateTime? _lastIcy;
  String? _key;
  void start() {
    unawaited(_poll());
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    _client.close(force: true);
  }

  void _publish(Map<String, String> fields) {
    if (_closed ||
        !(fields.containsKey('title') || fields.containsKey('streamTitle')))
      return;
    final value = RadioTrackMetadata.fromFields(fields);
    if (_key == value.key) return;
    _key = value.key;
    onChanged(value);
  }

  Future<void> _poll() async {
    try {
      final fields = await native();
      if (!_closed && fields['source'] == source) _publish(fields);
    } catch (_) {
      /* Metadata cannot interrupt the independently owned audio. */
    }
    if (_closed) return;
    if (_lastIcy == null ||
        DateTime.now().difference(_lastIcy!) >= const Duration(seconds: 15)) {
      _lastIcy = DateTime.now();
      final uri = Uri.tryParse(source);
      if (uri != null && const {'http', 'https'}.contains(uri.scheme)) {
        try {
          _publish(
            await readIcyMetadata(
              _client,
              uri,
            ).timeout(const Duration(seconds: 8)),
          );
        } catch (_) {
          /* No metadata is a valid station capability. */
        }
      }
    }
    if (!_closed) _timer = Timer(const Duration(seconds: 3), _poll);
  }
}
