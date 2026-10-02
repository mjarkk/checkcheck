import 'package:flutter/material.dart';

/// Shared with the web app; see "Shared look" in /API.md.
const seedColor = Color(0xFF6750A4);

/// Bundled variable font, the same family the web app loads.
const fontFamily = 'RobotoFlex';

/// The web app's `--md-sys-elevation-2`.
const elevation2 = [
  BoxShadow(color: Color(0x4D000000), offset: Offset(0, 1), blurRadius: 2),
  BoxShadow(
    color: Color(0x26000000),
    offset: Offset(0, 2),
    blurRadius: 6,
    spreadRadius: 2,
  ),
];

/// The web app's `--md-sys-elevation-3`.
const elevation3 = [
  BoxShadow(color: Color(0x4D000000), offset: Offset(0, 1), blurRadius: 3),
  BoxShadow(
    color: Color(0x26000000),
    offset: Offset(0, 4),
    blurRadius: 8,
    spreadRadius: 3,
  ),
];

/// The web app's `--more-btn-color`: darker than the headings it ends.
Color moreButtonColor(ColorScheme colors) => switch (colors.brightness) {
  Brightness.light => colors.onPrimaryContainer,
  // primary-container itself is too dark to read on the dark surface.
  Brightness.dark => Color.lerp(colors.primaryContainer, colors.primary, 0.7)!,
};

/// The web app's `.btn-large`, layered over the button themes below.
final largeButton = ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(64, 56)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 32)),
  textStyle: WidgetStatePropertyAll(
    _flex(16, 24, FontWeight.w600, letterSpacing: 0.16),
  ),
  shape: _pressMorph(16),
);

// The SDK has no Material 3 Expressive components; theming approximates them.
// Sizes and weights mirror server/web/src/styles.css.
ThemeData buildTheme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: seedColor,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
    brightness: brightness,
  );
  final text = TextTheme(
    displayLarge: _flex(57, 64, FontWeight.w800, width: 112),
    displayMedium: _flex(45, 52, FontWeight.w800, width: 112),
    displaySmall: _flex(
      44,
      46,
      FontWeight.w800,
      width: 112,
      letterSpacing: -1.54,
    ),
    headlineLarge: _flex(32, 40, _w750, width: 108),
    headlineMedium: _flex(28, 36, _w750, width: 108),
    headlineSmall: _flex(26, 32, _w750, width: 108, letterSpacing: -0.39),
    titleLarge: _flex(22, 28, _w750, width: 110, letterSpacing: -0.22),
    titleMedium: _flex(16, 24, FontWeight.w500),
    titleSmall: _flex(14, 20, _w750, letterSpacing: 0.28),
    bodyLarge: _flex(16, 24, FontWeight.w400),
    bodyMedium: _flex(14, 20, FontWeight.w400),
    bodySmall: _flex(12, 16, FontWeight.w400),
    labelLarge: _flex(14, 20, FontWeight.w600, letterSpacing: 0.14),
    labelMedium: _flex(13, 20, FontWeight.w500),
    labelSmall: _flex(11, 16, FontWeight.w500),
  ).apply(bodyColor: colors.onSurface, displayColor: colors.onSurface);

  final fieldBorder = UnderlineInputBorder(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
    borderSide: BorderSide(color: colors.onSurfaceVariant),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    fontFamily: fontFamily,
    textTheme: text,
    // State layers only, like the web app's hover/pressed overlays.
    splashFactory: NoSplash.splashFactory,
    highlightColor: colors.onSurface.withValues(alpha: 0.1),
    appBarTheme: const AppBarTheme(scrolledUnderElevation: 0),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceContainerHigh,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyLarge?.copyWith(
        fontSize: 15,
        color: colors.onSurfaceVariant,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 24),
        ),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        shape: _pressMorph(12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        shape: _pressMorph(12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.square(40)),
        fixedSize: const WidgetStatePropertyAll(Size.square(40)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: _pressMorph(12),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainer),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(textStyle: WidgetStatePropertyAll(text.bodyLarge)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceContainer,
      textStyle: text.bodyLarge,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.surfaceContainerHighest,
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: colors.primary, width: 3),
      ),
      errorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: colors.error, width: 2),
      ),
      focusedErrorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: colors.error, width: 3),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: colors.primaryContainer,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 3,
      showCloseIcon: true,
      closeIconColor: colors.onInverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(
        color: colors.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

WidgetStateProperty<OutlinedBorder> _pressMorph(double pressedRadius) =>
    WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.pressed)
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(pressedRadius),
            )
          : const StadiumBorder(),
    );

const _w750 = FontWeight(750);

/// CSS sets `opsz` from the font size on its own; Flutter doesn't.
TextStyle _flex(
  double size,
  double lineHeight,
  FontWeight weight, {
  double width = 100,
  double letterSpacing = 0,
}) => TextStyle(
  fontFamily: fontFamily,
  fontSize: size,
  height: lineHeight / size,
  fontWeight: weight,
  letterSpacing: letterSpacing,
  fontVariations: [FontVariation.width(width), FontVariation.opticalSize(size)],
);
