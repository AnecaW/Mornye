import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';

/// Presentation only: a zero-duration song is not necessarily a broadcast.
bool isLiveBroadcastId(String? id) =>
    id?.startsWith('subsonic-radio://') ?? false;

final liveBroadcastSelectedProvider = Provider<bool>(
  (ref) => ref.watch(
    currentMediaItemProvider.select(
      (item) => isLiveBroadcastId(item.value?.id),
    ),
  ),
);

/// No seek semantics, thumb, elapsed time or simulated progress.
class LiveBroadcastTimeline extends StatefulWidget {
  const LiveBroadcastTimeline({
    super.key,
    required this.playing,
    required this.loading,
    this.colorScheme,
    this.compact = false,
  });
  final bool playing;
  final bool loading;
  final ColorScheme? colorScheme;
  final bool compact;
  @override
  State<LiveBroadcastTimeline> createState() => _LiveBroadcastTimelineState();
}

class _LiveBroadcastTimelineState extends State<LiveBroadcastTimeline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant LiveBroadcastTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final animate =
        widget.playing &&
        !widget.loading &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.of(context);
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!animate) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.colorScheme ?? Theme.of(context).colorScheme;
    final active = widget.playing && !widget.loading;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    final status = widget.loading
        ? context.l10n.liveBroadcastConnecting
        : active
        ? 'LIVE'
        : context.l10n.liveBroadcastPaused;
    return Semantics(
      label: 'LIVE',
      value: status,
      container: true,
      excludeSemantics: true,
      child: SizedBox(
        height: widget.compact ? 24 : 48,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) => Row(
            children: [
              Expanded(child: _line(color, leading: true)),
              Flexible(
                flex: 3,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.compact ? 10 : 18,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.loading)
                        AppLoadingIndicator(
                          size: widget.compact ? 10 : 14,
                          color: color,
                        )
                      else
                        Container(
                          width: widget.compact ? 5 : 7,
                          height: widget.compact ? 5 : 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color.withValues(
                              alpha: active ? 0.6 + _pulse.value * 0.4 : 0.4,
                            ),
                            boxShadow: active
                                ? [
                                    BoxShadow(
                                      color: color.withValues(
                                        alpha: _pulse.value * 0.18,
                                      ),
                                      blurRadius: 8,
                                      spreadRadius: 2,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        'LIVE',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                            ),
                      ),
                      if (!active && !widget.compact) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(color: color),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(child: _line(color, leading: false)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(Color color, {required bool leading}) => Container(
    height: 2,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(2),
      gradient: LinearGradient(
        colors: leading
            ? [color.withValues(alpha: 0.02), color.withValues(alpha: 0.35)]
            : [color.withValues(alpha: 0.35), color.withValues(alpha: 0.02)],
      ),
    ),
  );
}

class LiveBroadcastPlayButton extends ConsumerWidget {
  const LiveBroadcastPlayButton({
    super.key,
    this.colorScheme,
    this.compact = false,
  });
  final ColorScheme? colorScheme;
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playbackPlayingProvider);
    final loading = ref.watch(playbackLoadingProvider);
    final scheme = colorScheme ?? Theme.of(context).colorScheme;
    final controller = ref.read(musicPlayerControllerProvider);
    final tooltip = playing
        ? context.l10n.actionPause
        : context.l10n.tooltipPlay;
    if (context.isMornye) {
      return MornyePlaybackButton(
        icon: playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
        color: scheme.onSurface,
        iconSize: compact ? 22 : 48,
        tooltip: tooltip,
        loading: loading,
        onPressed: () => controller.togglePlayPause(playing),
      );
    }
    return ExpressiveIconButton(
      size: compact ? 40 : 68,
      iconSize: compact ? 22 : 44,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      tooltip: tooltip,
      selected: playing,
      icon: loading
          ? AppLoadingIndicator(
              size: compact ? 20 : 32,
              color: scheme.onPrimary,
            )
          : Icon(playing ? Icons.pause : Icons.play_arrow),
      onPressed: () => controller.togglePlayPause(playing),
    );
  }
}

class LiveBroadcastControls extends ConsumerWidget {
  const LiveBroadcastControls({
    super.key,
    required this.colorScheme,
    this.compact = false,
  });
  final ColorScheme colorScheme;
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: EdgeInsets.symmetric(horizontal: context.tokens.rowPaddingH),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LiveBroadcastTimeline(
          playing: ref.watch(playbackPlayingProvider),
          loading: ref.watch(playbackLoadingProvider),
          colorScheme: colorScheme,
        ),
        const SizedBox(height: 12),
        LiveBroadcastPlayButton(colorScheme: colorScheme, compact: compact),
      ],
    ),
  );
}
