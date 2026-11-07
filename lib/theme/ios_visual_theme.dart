import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mornye/theme/app_theme.dart';

/// iOS appearance for the Flutter widgets that still provide the app's
/// layout, form decoration or routing. Keep the original sizing properties.
ThemeData iosVisualTheme(ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  Color resolve(CupertinoDynamicColor color) =>
      dark ? color.darkColor : color.color;
  final foreground = resolve(CupertinoColors.label);
  final secondary = resolve(CupertinoColors.secondaryLabel);
  final separator = resolve(CupertinoColors.separator);
  final grouped = resolve(CupertinoColors.secondarySystemGroupedBackground);
  final page = resolve(CupertinoColors.systemBackground);
  final groupedPage = resolve(CupertinoColors.systemGroupedBackground);
  final fill = resolve(CupertinoColors.tertiarySystemFill);
  final cupertino = CupertinoThemeData(
    brightness: theme.brightness,
    primaryColor: theme.colorScheme.primary,
  );
  final currentFamily = theme.textTheme.bodyLarge?.fontFamily;
  final systemFamily = currentFamily == null
      ? cupertino.textTheme.textStyle.fontFamily
      : currentFamily == AppTheme.bundledFontFamily
      ? cupertino.textTheme.navLargeTitleTextStyle.fontFamily
      : null;
  const pill = WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder());
  const flat = WidgetStatePropertyAll<double>(0);
  ButtonStyle restyle(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        shape: pill,
        elevation: flat,
        splashFactory: NoSplash.splashFactory,
      );
  OutlineInputBorder border(BorderSide side) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: side,
  );

  return theme.copyWith(
    colorScheme: theme.colorScheme.copyWith(
      surface: page,
      onSurface: foreground,
      onSurfaceVariant: secondary,
      surfaceContainerLowest: page,
      surfaceContainerLow: groupedPage,
      surfaceContainer: grouped,
      outlineVariant: separator,
    ),
    textTheme: theme.textTheme.apply(fontFamily: systemFamily),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: systemFamily),
    splashFactory: NoSplash.splashFactory,
    dividerColor: separator,
    dividerTheme: theme.dividerTheme.copyWith(color: separator),
    cupertinoOverrideTheme: cupertino,
    filledButtonTheme: FilledButtonThemeData(
      style: restyle(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: restyle(theme.outlinedButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: restyle(theme.elevatedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: restyle(theme.textButtonTheme.style),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: restyle(theme.iconButtonTheme.style),
    ),
    floatingActionButtonTheme: theme.floatingActionButtonTheme.copyWith(
      shape: const StadiumBorder(),
      elevation: 0,
      highlightElevation: 0,
      disabledElevation: 0,
    ),
    chipTheme: theme.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide.none,
    ),
    cardTheme: theme.cardTheme.copyWith(color: grouped, elevation: 0),
    progressIndicatorTheme: theme.progressIndicatorTheme.copyWith(
      linearTrackColor: fill,
      borderRadius: BorderRadius.circular(4),
      trackGap: 0,
      stopIndicatorRadius: 0,
    ),
    popupMenuTheme: theme.popupMenuTheme.copyWith(
      color: grouped,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      backgroundColor: grouped,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: theme.bottomSheetTheme.copyWith(
      backgroundColor: grouped,
      modalBackgroundColor: grouped,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: fill,
      hintStyle:
          theme.inputDecorationTheme.hintStyle?.copyWith(color: secondary) ??
          TextStyle(color: secondary),
      labelStyle:
          theme.inputDecorationTheme.labelStyle?.copyWith(color: foreground) ??
          TextStyle(color: foreground),
      border: border(BorderSide.none),
      enabledBorder: border(BorderSide.none),
      focusedBorder: border(BorderSide(color: theme.colorScheme.primary)),
    ),
  );
}
