import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/controllers/open_audio_controller.dart';
import 'package:mornye/services/audio_file_open_service.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/providers/playback_provider.dart' show playbackProvider;
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/providers/track_provider.dart';

/// Presentation adapter only. All commands go through the same controllers as
/// the cross-platform UI; this layer never implements playback or downloads.
class NativeIPhoneRuntime extends ConsumerStatefulWidget {
  const NativeIPhoneRuntime({super.key});
  static Future<void> openPlayer() =>
      _NativeIPhoneRuntimeState.channel.invokeMethod<void>('openPlayer');
  @override
  ConsumerState<NativeIPhoneRuntime> createState() =>
      _NativeIPhoneRuntimeState();
}

class _NativeIPhoneRuntimeState extends ConsumerState<NativeIPhoneRuntime> {
  static const channel = MethodChannel('com.zarz.mornye/native_iphone');
  final Map<String, PlayableMedia> _media = {};
  final Map<String, Track> _searchTracks = {};
  final PlayerMetadataController _metadata = PlayerMetadataController();
  Timer? _publishTimer;
  bool _publishing = false;
  bool _dirty = true;
  StreamSubscription<List<OpenAudioFile>>? _audioOpen;

  @override
  void initState() {
    super.initState();
    channel.setMethodCallHandler(_handle);
    final audio = AudioFileOpenService.instance;
    _audioOpen = audio.requests.listen((files) => unawaited(_openAudio(files)));
    for (final files in audio.takePending()) {
      unawaited(_openAudio(files));
    }
    _publishTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_dirty) unawaited(_publish());
    });
    unawaited(_publish());
  }

  MusicPlayerController get player => ref.read(musicPlayerControllerProvider);

  Future<void> _openAudio(List<OpenAudioFile> files) async {
    try {
      await ref.read(openAudioControllerProvider.notifier).open(files);
      await NativeIPhoneRuntime.openPlayer();
    } catch (error) {
      await channel.invokeMethod<void>('error', {'message': error.toString()});
    }
  }

  Map<String, Object?> _song(PlayableMedia media) {
    _media[media.id] = media;
    return {
      'id': media.id,
      'title': media.title,
      'artist': media.artist,
      'album': media.album,
      'artwork': media.artUri ?? '',
      'duration': media.duration?.inSeconds ?? 0,
      'quality': [
        media.format?.toUpperCase(),
        if (media.bitDepth != null) '${media.bitDepth} bit',
        if (media.sampleRate != null) '${media.sampleRate! / 1000} kHz',
      ].whereType<String>().join(' · '),
    };
  }

  Map<String, Object?> _now(MediaItem item) => {
    'id': item.id,
    'title': item.title,
    'artist': item.artist ?? '',
    'album': item.album ?? '',
    'artwork': item.artUri?.toString() ?? '',
    'duration': item.duration?.inSeconds ?? 0,
  };

  Map<String, Object?> _catalog(Track track) {
    _searchTracks[track.id] = track;
    return {
      'id': track.id,
      'title': track.name,
      'artist': track.artistName,
      'album': track.albumName,
      'artwork': track.coverUrl ?? '',
      'duration': track.duration / 1000,
    };
  }

  Future<Track> _track(String id) async {
    final now = ref.read(currentMediaItemProvider).value;
    if (now != null && now.id == id) {
      return ref.read(playerCollectionTrackProvider(now).future);
    }
    final catalog = _searchTracks[id];
    if (catalog != null) return catalog;
    final media = _media[id];
    if (media == null) throw StateError('This song is no longer available.');
    return Track(
      id: media.id,
      name: media.title,
      artistName: media.artist,
      albumName: media.album,
      coverUrl: media.artUri,
      duration: media.duration?.inMilliseconds ?? 0,
    );
  }

  Future<void> _publish() async {
    if (!mounted || _publishing) return;
    _publishing = true;
    _dirty = false;
    try {
      final media = ref.read(currentMediaItemProvider).value;
      final playback = ref.read(playbackStateProvider).value;
      final downloads = ref.read(downloadQueueProvider);
      final extensions = ref.read(extensionProvider);
      final library = ref.read(localLibraryProvider);
      final settings = ref.read(settingsProvider);
      final collections = ref.read(libraryCollectionsProvider);
      await channel.invokeMethod<void>('state', {
        'ready': true,
        'playlists': collections.playlists
            .map(
              (list) => {
                'id': list.id,
                'title': list.name,
                'count': list.trackCount,
              },
            )
            .toList(),
        'lovedCount': collections.loved.length,
        'firstLaunch': settings.isFirstLaunch,
        'now': media == null ? null : _now(media),
        'playing': playback?.playing ?? false,
        'position': playback?.position.inMilliseconds.toDouble() ?? 0,
        'shuffle': playback?.shuffleMode == AudioServiceShuffleMode.all,
        'repeat': playback?.repeatMode.name ?? 'none',
        'queue': (ref.read(playQueueProvider).value ?? <MediaItem>[])
            .map(_now)
            .toList(),
        'downloadsPaused': downloads.isPaused,
        'downloads': downloads.items
            .map(
              (item) => {
                'id': item.id,
                'title': item.track.name,
                'artist': item.track.artistName,
                'artwork': item.track.coverUrl ?? '',
                'status': item.status.name,
                'progress': item.progress,
                'error': item.error ?? '',
              },
            )
            .toList(),
        'extensions': extensions.extensions
            .map(
              (ext) => {
                'id': ext.id,
                'title': ext.displayName,
                'version': ext.version,
                'description': ext.description,
                'enabled': ext.enabled,
                'canDownload': ext.hasDownloadProvider,
                'qualities': ext.qualityOptions
                    .map((q) => {'id': q.id, 'title': q.label})
                    .toList(),
              },
            )
            .toList(),
        'sources': library.sources
            .map(
              (source) => {
                'id': source.id,
                'title': source.displayName,
                'enabled': source.enabled,
              },
            )
            .toList(),
        'scanning': library.isScanning,
        'libraryRevision':
            '${library.loadedIndexVersion}:${library.totalCount}:${downloads.items.where((item) => item.status.name == 'completed').length}',
        'settings': {
          'gaplessPlayback': settings.gaplessPlayback,
          'autoplay': settings.autoplay,
          'playbackNormalization': settings.playbackNormalization,
          'musicHaptics': settings.musicHaptics,
          'embedLyrics': settings.embedLyrics,
          'embedMetadata': settings.embedMetadata,
          'autoFallback': settings.autoFallback,
          'audioQuality': settings.audioQuality,
          'defaultService': settings.defaultService,
        },
      });
    } on MissingPluginException {
      _dirty = true;
    } finally {
      _publishing = false;
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final id = args['id'] as String? ?? '';
    switch (call.method) {
      case 'refresh':
        _dirty = true;
        await _publish();
        return null;
      case 'artwork':
        return ref
            .read(musicPlayerRuntimeProvider)
            .dependencies
            .coverStore
            .file(args['path'] as String);
      case 'lyrics':
      case 'searchLyrics':
        final item = ref.read(currentMediaItemProvider).value;
        await _metadata.load(item);
        if (call.method == 'searchLyrics') await _metadata.searchOnline();
        final lyrics = _metadata.lyrics;
        return {
          'id': _metadata.item?.id ?? '',
          'synced': lyrics.synced,
          'plain': lyrics.plainText,
          'lines': lyrics.lines
              .map(
                (line) => {
                  'text': line.text,
                  'time': line.time.inMilliseconds,
                  'translation': line.translation ?? '',
                },
              )
              .toList(),
        };
      case 'trackDetails':
        return _metadata.readDetails(ref.read(currentMediaItemProvider).value);
      case 'library':
        // The existing browser includes both downloaded and scanned music,
        // and applies the user's existing source visibility rules.
        final songs = await ref
            .read(musicPlayerRuntimeProvider)
            .browser
            .librarySongs();
        _media.clear();
        return songs.map(_song).toList();
      case 'collection':
        final notifier = ref.read(libraryCollectionsProvider.notifier);
        if (id != 'loved') await notifier.ensurePlaylistLoaded(id);
        final collections = ref.read(libraryCollectionsProvider);
        final entries = id == 'loved'
            ? collections.loved
            : collections.playlistById(id)?.tracks ?? <CollectionTrackEntry>[];
        return entries.map((entry) => _catalog(entry.track)).toList();
      case 'createPlaylist':
        return ref
            .read(libraryCollectionsProvider.notifier)
            .createPlaylist(args['name'] as String);
      case 'addToPlaylist':
        await ref
            .read(libraryCollectionsProvider.notifier)
            .addTrackToPlaylist(args['playlist'] as String, await _track(id));
      case 'love':
        await ref
            .read(libraryCollectionsProvider.notifier)
            .toggleLoved(await _track(id));
      case 'playCatalog':
        final ids = (args['ids'] as List).cast<String>();
        final tracks = <Track>[];
        for (final id in ids) {
          tracks.add(await _track(id));
        }
        await ref
            .read(playbackProvider.notifier)
            .playTrackList(tracks, startIndex: args['index'] as int? ?? 0);
      case 'play':
        final media = _media[id];
        if (media == null) {
          throw StateError(
            'This song is no longer available. Refresh your library.',
          );
        }
        await ref
            .read(playbackProvider.notifier)
            .playMediaQueue([media], startIndex: 0, externalPath: media.source);
      case 'playAll':
        final ids = (args['ids'] as List).cast<String>();
        final songs = ids
            .map((id) => _media[id])
            .whereType<PlayableMedia>()
            .toList();
        if (songs.isEmpty) {
          throw StateError('No playable songs in this collection.');
        }
        final index = (args['index'] as int? ?? 0).clamp(0, songs.length - 1);
        await ref
            .read(playbackProvider.notifier)
            .playMediaQueue(
              songs,
              startIndex: index,
              externalPath: songs[index].source,
            );
      case 'toggle':
        await player.ensureInitialized();
        await player.togglePlayPause(ref.read(playbackPlayingProvider));
      case 'next':
        await player.next();
      case 'previous':
        await player.previous();
      case 'seek':
        await player.seek(
          Duration(milliseconds: (args['position'] as num).round()),
        );
      case 'shuffle':
        await player.setShuffle(args['enabled'] as bool);
      case 'repeat':
        await player.setRepeatMode(
          AudioServiceRepeatMode.values.byName(args['mode'] as String),
        );
      case 'jump':
        await player.jumpTo(args['index'] as int);
      case 'enqueue':
        final media = _media[id];
        if (media == null) throw StateError('Refresh your library first.');
        await player.addToQueue(media);
      case 'shuffleLibrary':
        if (!await player.shuffleLibrary()) {
          throw StateError('Add music to your library first.');
        }
      case 'search':
        final query = (args['query'] as String).trim();
        if (query.isEmpty) return [];
        await ref.read(extensionProvider.notifier).ensureInitialized();
        await ref
            .read(trackProvider.notifier)
            .search(query, filterOverride: 'track');
        final result = ref.read(trackProvider);
        if (result.error != null) throw StateError(result.error!);
        return result.tracks
            .where((track) => !track.isCollection)
            .map(_catalog)
            .toList();
      case 'download':
        final track = _searchTracks[id];
        if (track == null) throw StateError('Search for this song again.');
        final service = ref.read(settingsProvider).defaultService;
        if (service.isEmpty) {
          throw StateError('Choose a download provider in Settings first.');
        }
        ref.read(downloadQueueProvider.notifier).addIndividualTracksToQueue([
          track,
        ], service);
      case 'pauseDownloads':
        ref.read(downloadQueueProvider.notifier).togglePause();
      case 'retryDownload':
        await ref.read(downloadQueueProvider.notifier).retryItem(id);
      case 'cancelDownload':
        ref.read(downloadQueueProvider.notifier).cancelItem(id);
      case 'toggleExtension':
        await ref
            .read(extensionProvider.notifier)
            .setExtensionEnabled(id, args['enabled'] as bool);
      case 'extensionSettings':
        final extension = ref
            .read(extensionProvider)
            .extensions
            .where((ext) => ext.id == id)
            .first;
        final values = await PlatformBridge.getExtensionSettings(id);
        return {
          'fields': extension.settings
              .map(
                (field) => {
                  'id': field.key,
                  'title': field.label,
                  'type': field.type,
                  'description': field.description ?? '',
                  'options': field.options ?? <String>[],
                  'action': field.action ?? '',
                  'value': values[field.key] ?? field.defaultValue ?? '',
                },
              )
              .toList(),
        };
      case 'saveExtensionSetting':
        final values = await PlatformBridge.getExtensionSettings(id);
        if (!await ref.read(extensionProvider.notifier).setExtensionSettings(
          id,
          {...values, args['key'] as String: args['value']},
        )) {
          throw StateError('Could not save extension settings.');
        }
      case 'extensionAction':
        final result = await PlatformBridge.invokeExtensionAction(
          id,
          args['action'] as String,
          input: args['input'] == null
              ? null
              : Map<String, dynamic>.from(args['input'] as Map),
        );
        final payload = result['result'] is Map
            ? Map<String, dynamic>.from(result['result'] as Map)
            : result;
        final auth = payload['auth_url'];
        if (auth is String && auth.isNotEmpty) {
          await launchExtensionAuthUrl(
            Uri.parse(auth),
            browserMode: 'in_app_first',
          );
        }
        return payload;
      case 'store':
        final temp = await getTemporaryDirectory();
        await PlatformBridge.initExtensionRepo(temp.path);
        final rows = await PlatformBridge.getRepoExtensions();
        return rows;
      case 'install':
        final temp = await getTemporaryDirectory();
        final path = await PlatformBridge.downloadRepoExtension(id, temp.path);
        if (!await ref
            .read(extensionProvider.notifier)
            .installExtension(path)) {
          throw StateError('The extension could not be installed.');
        }
      case 'addFolder':
        final directory = await PlatformBridge.pickIosDirectory();
        if (directory == null) return null;
        final library = ref.read(localLibraryProvider.notifier);
        ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
        final source = await library.addSource(
          path: directory.path,
          displayName: directory.path.split('/').last,
          bookmark: directory.bookmark,
        );
        unawaited(library.startSourceScan(source.id));
      case 'scan':
        unawaited(ref.read(localLibraryProvider.notifier).startSourceScan(id));
      case 'openFiles':
        await ref.read(openAudioControllerProvider.notifier).pickFiles();
      case 'completeSetup':
        final settings = ref.read(settingsProvider.notifier);
        if (ref.read(settingsProvider).downloadDirectory.isEmpty) {
          final docs = await getApplicationDocumentsDirectory();
          await settings.useAppFolderStorage(docs.path);
        }
        await settings.setFirstLaunchComplete();
        settings.setTutorialComplete();
      case 'setting':
        final settings = ref.read(settingsProvider.notifier);
        final value = args['value'];
        switch (args['key']) {
          case 'gaplessPlayback':
            settings.setGaplessPlayback(value as bool);
          case 'autoplay':
            settings.setAutoplay(value as bool);
          case 'playbackNormalization':
            settings.setPlaybackNormalization(value as bool);
          case 'musicHaptics':
            settings.setMusicHaptics(value as bool);
          case 'embedLyrics':
            settings.setEmbedLyrics(value as bool);
          case 'embedMetadata':
            settings.setEmbedMetadata(value as bool);
          case 'autoFallback':
            settings.setAutoFallback(value as bool);
          case 'audioQuality':
            settings.setAudioQuality(value as String);
          case 'defaultService':
            settings.setDefaultService(value as String);
          default:
            throw ArgumentError('Unknown setting');
        }
      default:
        throw MissingPluginException(
          'Unknown native UI command: ${call.method}',
        );
    }
    _dirty = true;
    await _publish();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentMediaItemProvider, (_, _) => _dirty = true);
    ref.listen(playbackStateProvider, (_, _) => _dirty = true);
    ref.listen(playQueueProvider, (_, _) => _dirty = true);
    ref.listen(downloadQueueProvider, (_, _) => _dirty = true);
    ref.listen(extensionProvider, (_, _) => _dirty = true);
    ref.listen(localLibraryProvider, (_, _) => _dirty = true);
    ref.listen(settingsProvider, (_, _) => _dirty = true);
    ref.listen(libraryCollectionsProvider, (_, _) => _dirty = true);
    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    _publishTimer?.cancel();
    unawaited(_audioOpen?.cancel());
    _metadata.dispose();
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
