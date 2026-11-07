import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/ios_system_view.dart';

/// Expressive actions retain caller colors, disabled states and flexible labels.
class ExpressiveButton extends StatelessWidget {
  const ExpressiveButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.style,
    this.outlined = false,
    this.tonal = false,
    this.text = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final ButtonStyle? style;
  final bool outlined;
  final bool tonal;

  /// Low-emphasis action without a container, like [TextButton].
  final bool text;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon == null ? null : symbolIconWidget(this.icon!);
    if (usesIosVisualStyle && style == null) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final prominent = !text && !outlined && !tonal;
      final foreground = prominent ? colors.onPrimary : colors.primary;
      return CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        borderRadius: BorderRadius.circular(28),
        color: prominent
            ? colors.primary
            : text
            ? null
            : CupertinoColors.tertiarySystemFill.resolveFrom(context),
        onPressed: onPressed,
        child: DefaultTextStyle.merge(
          style: (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
            color: foreground,
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: foreground, size: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[icon, const SizedBox(width: 8)],
                Flexible(child: child),
              ],
            ),
          ),
        ),
      );
    }
    if (usesIosVisualStyle || !materialExpressiveEnabled(context)) {
      if (icon != null) {
        // Keep the standard icon spacing and asymmetric padding.
        if (text) {
          return TextButton.icon(
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        if (outlined) {
          return OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        if (tonal) {
          return FilledButton.tonalIcon(
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        return FilledButton.icon(
          onPressed: onPressed,
          style: style,
          icon: icon,
          label: child,
        );
      }
      if (text) {
        return TextButton(onPressed: onPressed, style: style, child: child);
      }
      if (outlined) {
        return OutlinedButton(onPressed: onPressed, style: style, child: child);
      }
      if (tonal) {
        return FilledButton.tonal(
          onPressed: onPressed,
          style: style,
          child: child,
        );
      }
      return FilledButton(onPressed: onPressed, style: style, child: child);
    }
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[icon, const SizedBox(width: 8)],
        Flexible(child: child),
      ],
    );
    final states = <WidgetState>{if (onPressed == null) WidgetState.disabled};
    return MaterialExpressiveScope(
      child: M3EButton(
        onPressed: onPressed,
        style: text
            ? M3EButtonStyle.text
            : outlined
            ? M3EButtonStyle.outlined
            : tonal
            ? M3EButtonStyle.tonal
            : M3EButtonStyle.filled,
        decoration: M3EButtonDecoration(
          backgroundColor: style?.backgroundColor,
          foregroundColor: style?.foregroundColor,
          overlayColor: style?.overlayColor,
          side: style?.side,
          minimumSize:
              style?.minimumSize?.resolve(states) ?? const Size(48, 48),
          maximumSize: style?.maximumSize?.resolve(states),
          fixedSize: style?.fixedSize?.resolve(states),
          padding: style?.padding?.resolve(states),
          textStyle: style?.textStyle?.resolve(states),
          iconSize: style?.iconSize?.resolve(states),
        ),
        child: content,
      ),
    );
  }
}
