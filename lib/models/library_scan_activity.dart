/// Actual work reported by the scanner; an unknown total stays indeterminate.
class LibraryScanActivity {
  const LibraryScanActivity({
    required this.phase,
    this.processed = 0,
    this.total,
    this.albums = 0,
    this.artists = 0,
    this.elapsed = Duration.zero,
  });
  final String phase;
  final int processed, albums, artists;
  final int? total;
  final Duration elapsed;
  double? get fraction =>
      total != null && total! > 0 ? (processed / total!).clamp(0.0, 1.0) : null;
  // The average over the whole phase damps noisy per-request timing. Wait for
  // enough observations; this estimate covers this phase, not database commit.
  Duration? get remaining =>
      total != null &&
          total! > processed &&
          processed >= 10 &&
          elapsed.inSeconds >= 3
      ? Duration(
          milliseconds:
              (elapsed.inMilliseconds * (total! - processed) / processed)
                  .round(),
        )
      : null;
}
