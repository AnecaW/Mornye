/// Protocol capabilities use the server-advertised API version, never invented endpoints.
/// Minimum versions: https://www.subsonic.org/pages/api.jsp
class SubsonicCapabilities {
  String? version;
  final _unsupported = <String>{};
  static const minimumVersions = <String, String>{
    'getArtists': '1.8.0',
    'getAlbum': '1.8.0',
    'getSong': '1.8.0',
    'getAlbumList2': '1.8.0',
    'getStarred2': '1.8.0',
    'search3': '1.8.0',
    'getInternetRadioStations': '1.9.0',
    'createInternetRadioStation': '1.16.0',
    'updateInternetRadioStation': '1.16.0',
    'deleteInternetRadioStation': '1.16.0',
    'getScanStatus': '1.15.0',
    'startScan': '1.15.0',
    'updatePlaylist': '1.8.0',
  };
  bool supportsMethod(String method) {
    if (_unsupported.contains(method)) return false;
    final minimum = minimumVersions[method], actual = version;
    if (minimum == null || actual == null) return true;
    final a = actual.split('.').map(int.tryParse).toList();
    final b = minimum.split('.').map(int.parse).toList();
    if (a.length < 3 || a.any((v) => v == null)) return true;
    for (var i = 0; i < 3; i++) {
      if (a[i]! > b[i]) return true;
      if (a[i]! < b[i]) return false;
    }
    return true;
  }

  void observe(Map<String, dynamic> response) {
    if (response['version'] case final String advertised) {
      if (version != null && version != advertised) _unsupported.clear();
      version = advertised;
    }
  }

  // Code 30 explicitly means the server's API version is too old. Code 70
  // means missing data and MUST NOT disable an endpoint or whole library.
  void failed(String method, int code) {
    if (code == 30) _unsupported.add(method);
  }
}

enum MusicLibraryCapability {
  indexedCatalog,
  localFiles,
  progressiveStreaming,
  radio,
  playlists,
  playlistEditing,
  recentlyPlayed,
  recordPlayback,
  upload,
  offlineDownload,
}

class MusicLibrarySource {
  MusicLibrarySource({
    required this.id,
    required this.account,
    required this.enabled,
    required Set<MusicLibraryCapability> capabilities,
  }) : capabilities = Set.unmodifiable(capabilities);
  final String id, account;
  final bool enabled;
  final Set<MusicLibraryCapability> capabilities;
  bool supports(MusicLibraryCapability capability) =>
      enabled && capabilities.contains(capability);
}
