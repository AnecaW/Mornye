import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/local_library_provider.dart';

/// Appears only for real scan work; never invents an overall percentage.
class LibraryScanStatus extends ConsumerWidget {
  const LibraryScanStatus({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localLibraryProvider);
    final l = context.l10n;
    final source = state.sources
        .where((s) => s.id == state.scanningSourceId)
        .firstOrNull;
    if (!state.isScanning) {
      final failed = state.sources
          .where((s) => s.enabled && s.lastScanError != null)
          .firstOrNull;
      if (failed == null && !state.scanWasCancelled) {
        if (state.scanProgress == 100) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(l.libraryScanFinished),
          );
        }
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          state.scanWasCancelled
              ? l.libraryScanStopped
              : '${failed!.displayName}: ${l.libraryScanFailed}',
        ),
      );
    }
    final a = state.scanActivity;
    final network = source?.path.startsWith('network://') ?? false;
    final indexing = state.scanIsFinalizing || a?.phase == 'indexing';
    final fraction = indexing
        ? null
        : network
        ? a?.fraction
        : state.scanTotalFiles > 0
        ? state.scanProgress / 100
        : null;
    final phase = indexing
        ? l.libraryScanIndexing
        : switch (a?.phase) {
            'connecting' => l.libraryScanConnecting,
            'information' => l.libraryScanInformation,
            'catalogue' => l.libraryScanCatalogue,
            'artwork' => l.libraryScanArtwork,
            _ => l.libraryScanMetadata,
          };
    final eta = indexing ? null : a?.remaining;
    final seconds = eta?.inSeconds;
    final estimate = eta == null
        ? (state.scanTotalFiles == 0
              ? l.libraryScanUnknownTotal
              : l.libraryScanEstimating)
        : '${l.libraryScanPhaseEstimate}: ≈ ${seconds! >= 60 ? '${(seconds / 60).ceil()} min' : '${seconds}s'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${source?.displayName ?? l.libraryDeviceSource} · ${source?.lastScannedAt == null ? l.libraryScanInitial : l.libraryScanSync}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: l.dialogCancel,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () =>
                    ref.read(localLibraryProvider.notifier).cancelScan(),
              ),
            ],
          ),
          Text(phase),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 6),
          Text(
            '${state.scannedFiles}${state.scanTotalFiles > 0 ? ' / ${state.scanTotalFiles}' : ''} ${l.searchSongs}${fraction == null ? '' : ' · ${(fraction * 100).floor()}%'}',
          ),
          if (network && a != null)
            Text(
              '${l.searchAlbums}: ${a.albums} · ${l.searchArtists}: ${a.artists}',
            ),
          if (!indexing)
            Text(estimate, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
