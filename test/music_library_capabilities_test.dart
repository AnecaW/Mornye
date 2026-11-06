import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_library_capabilities.dart';

void main() {
  test('advertised API versions gate optional endpoints', () {
    final support = SubsonicCapabilities()..observe({'version': '1.8.0'});
    expect(support.supportsMethod('getArtists'), isTrue);
    expect(support.supportsMethod('getInternetRadioStations'), isFalse);
    expect(support.supportsMethod('startScan'), isFalse);
    support.observe({'version': '1.16.1'});
    expect(support.supportsMethod('getInternetRadioStations'), isTrue);
    expect(support.supportsMethod('updatePlaylist'), isTrue);
  });
  test('missing data and authentication do not disable valid capabilities', () {
    final support = SubsonicCapabilities();
    support.failed('getAlbum', 70);
    support.failed('getAlbum', 40);
    expect(support.supportsMethod('getAlbum'), isTrue);
    support.failed('getInternetRadioStations', 30);
    expect(support.supportsMethod('getInternetRadioStations'), isFalse);
  });
  test('a disabled source retains identity without active capabilities', () {
    final source = MusicLibrarySource(
      id: 'server:nas',
      account: 'account-fingerprint',
      enabled: false,
      capabilities: {MusicLibraryCapability.progressiveStreaming},
    );
    expect(source.id, 'server:nas');
    expect(
      source.supports(MusicLibraryCapability.progressiveStreaming),
      isFalse,
    );
    expect(
      source.capabilities,
      contains(MusicLibraryCapability.progressiveStreaming),
    );
  });
}
