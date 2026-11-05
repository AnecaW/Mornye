import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';

/// Indeterminate loading only. Downloads/analysis keep their real progress.
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({
    super.key,
    this.size = 32,
    this.color,
    this.semanticLabel,
    this.strokeWidth = 3,
  });

  final double size;
  final Color? color;
  final String? semanticLabel;

  /// Retained for existing callers; the morphing loader defines its own stroke.
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    return SizedBox.square(
      dimension: size,
      child: TickerMode(
        enabled: animate,
        child: MaterialExpressiveScope(
          child: FittedBox(
            child: M3ELoadingIndicator(
              size: 48,
              color: color ?? Theme.of(context).colorScheme.primary,
              rotationTurns: animate ? null : 0,
              semanticLabel: semanticLabel,
            ),
          ),
        ),
      ),
    );
  }
}
