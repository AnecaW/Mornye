import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';

Future<void> showLibraryScanDialog(BuildContext context) => showAppDialog<void>(
  context: context,
  builder: (context) => AppDialogSurface(
    maxWidth: 440,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.library_music_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.libraryScan,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const LibraryScanProgress(),
        ],
      ),
    ),
  ),
);

/// A compact entry to the shared scan dialog, rather than another progress UI.
class LibraryScanStatus extends ConsumerWidget {
  const LibraryScanStatus({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localLibraryProvider);
    if (!state.isScanning) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final source = state.sources
        .where((s) => s.id == state.scanningSourceId)
        .firstOrNull;
    final fraction =
        state.scanIsFinalizing || state.scanActivity?.phase == 'indexing'
        ? null
        : source?.path.startsWith('network://') == true
        ? state.scanActivity?.fraction
        : state.scanTotalFiles > 0
        ? (state.scanProgress / 100).clamp(0.0, 1.0)
        : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.tokens.rowPaddingH,
        0,
        context.tokens.rowPaddingH,
        8,
      ),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(context.tokens.radiusCard),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showLibraryScanDialog(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                if (state.scanIsPaused)
                  Icon(Icons.pause_circle_outline, color: scheme.primary)
                else if (fraction != null)
                  SizedBox.square(
                    dimension: 24,
                    child: AppProgressIndicator.circular(
                      value: fraction,
                      strokeWidth: 2,
                    ),
                  )
                else
                  AppLoadingIndicator(size: 24, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.scanIsPaused
                        ? context.l10n.libraryScanPaused
                        : context.l10n.libraryScanning,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Text(
                  '${state.scannedFiles}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Identical real scan details in Settings and the library's glass dialog.
class LibraryScanProgress extends ConsumerWidget {
  const LibraryScanProgress({
    super.key,
    this.onPause,
    this.onResume,
    this.onCancel,
  });
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localLibraryProvider);
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final source = state.sources
        .where((s) => s.id == state.scanningSourceId)
        .firstOrNull;
    if (!state.isScanning) {
      final failed = state.sources
          .where((s) => s.enabled && s.lastScanError != null)
          .firstOrNull;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Icon(
              failed != null
                  ? Icons.info_outline
                  : state.scanWasCancelled
                  ? Icons.pause_circle_outline
                  : Icons.check_circle_outline,
              color: scheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                state.scanWasCancelled
                    ? l.libraryScanStopped
                    : failed != null
                    ? l.libraryScanFailed
                    : l.libraryScanFinished,
              ),
            ),
          ],
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
    final paused = state.scanIsPaused;
    final actualFraction = paused && fraction == null
        ? 0.0
        : fraction?.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${source?.displayName ?? l.libraryDeviceSource} · ${source?.lastScannedAt == null ? l.libraryScanInitial : l.libraryScanSync}',
          style: Theme.of(context).textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        Text(
          paused ? l.libraryScanPaused : phase,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 220),
          child: SizedBox(
            key: ValueKey(actualFraction == null),
            height: 20,
            child: Center(
              child: AppProgressIndicator.linear(
                value: actualFraction,
                semanticsLabel: phase,
                semanticsValue: fraction == null
                    ? null
                    : '${(fraction * 100).floor()}%',
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '${state.scannedFiles}${state.scanTotalFiles > 0 ? ' / ${state.scanTotalFiles}' : ''} ${l.searchSongs}${fraction == null ? '' : ' · ${(fraction * 100).floor()}%'}',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        if (network && a != null) ...[
          const SizedBox(height: 4),
          Text(
            '${l.searchAlbums}: ${a.albums} · ${l.searchArtists}: ${a.artists}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (!indexing) ...[
          const SizedBox(height: 6),
          Text(
            estimate,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (!indexing && state.scanCurrentFile?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(
            state.scanCurrentFile!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Wrap(
            spacing: 8,
            children: [
              if (!network && !indexing)
                AppDialogAction(
                  onPressed: paused
                      ? onResume ??
                            () => ref
                                .read(localLibraryProvider.notifier)
                                .resumeScan()
                      : onPause ??
                            () => ref
                                .read(localLibraryProvider.notifier)
                                .pauseScan(),
                  child: Text(paused ? l.actionResume : l.actionPause),
                ),
              AppDialogAction(
                onPressed:
                    onCancel ??
                    () => ref.read(localLibraryProvider.notifier).cancelScan(),
                child: Text(l.dialogCancel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
