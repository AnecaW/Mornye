import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/ios_system_view.dart';

/// Task progress (downloads, scans, updates), determinate or not.
///
/// The Material theme draws the expressive wavy indicators. Mornye and
/// reduced motion keep Flutter's flat indicators with the same parameters.
class AppProgressIndicator extends StatelessWidget {
  const AppProgressIndicator.linear({
    super.key,
    this.value,
    this.color,
    this.trackColor,
    this.minHeight,
    this.borderRadius,
    this.semanticsLabel,
    this.semanticsValue,
    this.wavy = true,
    this.plainFallback = false,
  }) : strokeWidth = null,
       strokeCap = null,
       _circular = false;

  /// Fills the smaller side of its parent, or 48dp when unbounded.
  const AppProgressIndicator.circular({
    super.key,
    this.value,
    this.color,
    this.trackColor,
    this.strokeWidth,
    this.strokeCap,
    this.semanticsLabel,
    this.semanticsValue,
    this.wavy = true,
  }) : minHeight = null,
       borderRadius = null,
       plainFallback = false,
       _circular = true;

  /// Progress in `0..1`, or null for indeterminate.
  final double? value;
  final Color? color;
  final Color? trackColor;

  /// Height of the flat linear fallback; the wavy track keeps its own height.
  final double? minHeight;
  final BorderRadiusGeometry? borderRadius;
  final double? strokeWidth;

  /// Cap of the flat circular fallback; the wavy stroke is always round.
  final StrokeCap? strokeCap;
  final String? semanticsLabel;
  final String? semanticsValue;

  /// Whether determinate progress waves. Values that only change on a new
  /// step or refresh, such as goals, use the flat expressive track at the
  /// caller's thickness instead.
  final bool wavy;
  final bool plainFallback;
  final bool _circular;

  @override
  Widget build(BuildContext context) {
    final value = this.value?.clamp(0.0, 1.0);
    if (usesIosSystemViews && _circular) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final extent = constraints.biggest.shortestSide;
          final side = extent.isFinite ? extent : 48.0;
          if (side <= 0) return const SizedBox.shrink();
          return Semantics(
            label: semanticsLabel,
            value:
                semanticsValue ??
                (value == null ? null : '${(value * 100).round()}%'),
            child: SizedBox.square(
              dimension: side,
              child: value == null
                  ? CupertinoActivityIndicator(
                      radius: side / 2,
                      color: color,
                      animating:
                          TickerMode.valuesOf(context).enabled &&
                          !MediaQuery.disableAnimationsOf(context),
                    )
                  : CupertinoActivityIndicator.partiallyRevealed(
                      radius: side / 2,
                      color: color,
                      progress: value,
                    ),
            ),
          );
        },
      );
    }
    if (usesIosSystemViews && value != null) {
      return SizedBox(
        height: minHeight ?? 4,
        width: double.infinity,
        child: IosSystemView(
          kind: 'progress',
          configuration: {
            ...iosSystemAppearance(context),
            'value': value,
            'label': semanticsLabel,
            'description': semanticsValue,
            'tint': color?.toARGB32(),
            'trackTint': trackColor?.toARGB32(),
          },
        ),
      );
    }
    if (plainFallback ||
        usesIosVisualStyle ||
        !materialExpressiveEnabled(context)) {
      return _circular
          ? CircularProgressIndicator(
              value: value,
              color: color,
              backgroundColor: trackColor,
              strokeWidth: strokeWidth,
              strokeCap: strokeCap,
              semanticsLabel: semanticsLabel,
              semanticsValue: semanticsValue,
            )
          : LinearProgressIndicator(
              value: value,
              color: color,
              backgroundColor: trackColor,
              minHeight: minHeight,
              borderRadius: borderRadius,
              semanticsLabel: semanticsLabel,
              semanticsValue: semanticsValue,
            );
    }
    final scheme = Theme.of(context).colorScheme;
    final wavy = this.wavy || value == null;
    if (!_circular) {
      return _scope(
        value,
        wavy
            ? M3EProgressIndicator.linearWavy(
                value: value,
                color: color ?? scheme.primary,
                trackColor: trackColor,
                semanticsLabel: semanticsLabel,
                semanticsValue: semanticsValue,
              )
            : M3EProgressIndicator.linear(
                value: value,
                linearSize: M3EProgressIndicatorSize.s,
                strokeWidth: minHeight,
                trackStrokeWidth: minHeight,
                color: color ?? scheme.primary,
                trackColor: trackColor,
                semanticsLabel: semanticsLabel,
                semanticsValue: semanticsValue,
              ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final size = side.isFinite ? side : null;
        return _scope(
          value,
          wavy
              ? M3EProgressIndicator.circularWavy(
                  value: value,
                  size: size,
                  color: color ?? scheme.primary,
                  trackColor: trackColor,
                  strokeWidth: strokeWidth,
                  trackStrokeWidth: strokeWidth,
                  semanticsLabel: semanticsLabel,
                  semanticsValue: semanticsValue,
                )
              : M3EProgressIndicator.circular(
                  value: value,
                  size: size,
                  color: color ?? scheme.primary,
                  trackColor: trackColor,
                  strokeWidth: strokeWidth,
                  trackStrokeWidth: strokeWidth,
                  semanticsLabel: semanticsLabel,
                  semanticsValue: semanticsValue,
                ),
        );
      },
    );
  }

  /// The theme draws determinate waves flat near either end, where the
  /// wave phase has no visible effect, so the ticker is muted there.
  Widget _scope(double? value, Widget indicator) {
    return MaterialExpressiveScope(
      child: Builder(
        builder: (context) {
          final theme = M3ETheme.of(context).progressIndicatorTheme;
          final flat =
              value != null &&
              (_circular
                      ? theme.circular.amplitudeForProgress(value)
                      : theme.linear.amplitudeForProgress(value)) <=
                  0;
          return TickerMode(enabled: !flat, child: indicator);
        },
      ),
    );
  }
}
