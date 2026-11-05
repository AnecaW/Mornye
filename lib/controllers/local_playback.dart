import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_source_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/track_file_resolver.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

/// Plays [track] from download history or the local library when a matching
/// file already exists on disk.
///
/// Returns true when playback started (or when an error was surfaced to the
/// user), so callers can skip enqueueing a download; returns false when no
/// local copy is available. Stale history entries whose file no longer exists
/// are pruned as a side effect.
Future<bool> playLocalIfAvailable(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final historyNotifier = ref.read(downloadHistoryProvider.notifier);

  try {
    final scope = ref
        .read(musicLibraryScopeProvider)
        .apply(const QueueLibraryDbQuery());
    final result = await resolveTrackFiles(
      [track],
      library: LibraryDatabase.instance,
      history: HistoryDatabase.instance,
      includeLocal: scope.includeLocal,
      scope: scope,
    );
    await historyNotifier.removeManyFromHistory(result.missingHistoryIds);
    final path = result.paths.single;
    if (path == null) return false;
    await ref
        .read(playbackProvider.notifier)
        .playLocalPath(
          path: path,
          title: track.name,
          artist: track.artistName,
          album: track.albumName,
          coverUrl: track.coverUrl ?? '',
        );
    return true;
  } catch (e) {
    if (context.mounted) showCannotOpenFileSnackBar(context, e);
    return true;
  }
}
