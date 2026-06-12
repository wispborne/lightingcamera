import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// TriOS "Starsector" theme for Lightning Camera.
///
/// A dark sci-fi/HUD look — bright cyan accent on deep navy surfaces — ported
/// from the companion TriOS project's `StarsectorTriOSTheme`. The constants
/// below are the exact values from TriOS so the look matches the source.

/// Bright cyan accent — `RGBO(73, 252, 255, 1)`.
const Color kPrimary = Color(0xFF49FCFF);

/// Lighter cyan — `RGBO(59, 203, 232, 1)`.
const Color kSecondary = Color(0xFF3BCBE8);

/// Deep navy viewfinder/background surface — `RGBO(14, 22, 43, 1)`.
const Color kSurface = Color(0xFF0E162B);

/// Navy for cards/containers — `RGBO(32, 41, 65, 1)`.
const Color kSurfaceContainer = Color(0xFF202941);

/// Orange error color — `ARGB(255, 252, 99, 0)`.
const Color kError = Color(0xFFFC6300);

/// Gold warning color — `ARGB(255, 253, 212, 24)`.
const Color kWarning = Color(0xFFFDD418);

/// Corner radius used across cards, dialogs, and buttons.
const double kCornerRadius = 6;

/// Builds the single TriOS-styled dark [ThemeData] for the app.
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kPrimary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: kPrimary,
    secondary: kSecondary,
    surface: kSurface,
    error: kError,
    // Surface-container ramp derived by lightening/darkening kSurfaceContainer,
    // mirroring TriOS's dark-theme copyWith.
    surfaceContainerLowest: _shade(kSurfaceContainer, -0.06),
    surfaceContainerLow: _shade(kSurfaceContainer, -0.03),
    surfaceContainer: kSurfaceContainer,
    surfaceContainerHigh: _shade(kSurfaceContainer, 0.03),
    surfaceContainerHighest: _shade(kSurfaceContainer, 0.06),
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);

  // Instant page transitions on every platform so navigating between camera,
  // gallery, settings, map, and fullscreen images feels immediate — no slide
  // or fade delay to wait through.
  const instantTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: _InstantPageTransitionsBuilder(),
      TargetPlatform.iOS: _InstantPageTransitionsBuilder(),
      TargetPlatform.fuchsia: _InstantPageTransitionsBuilder(),
      TargetPlatform.linux: _InstantPageTransitionsBuilder(),
      TargetPlatform.macOS: _InstantPageTransitionsBuilder(),
      TargetPlatform.windows: _InstantPageTransitionsBuilder(),
    },
  );

  return base.copyWith(
    pageTransitionsTheme: instantTransitions,
    scaffoldBackgroundColor: kSurfaceContainer,
    cardColor: kSurfaceContainer,
    dialogTheme: const DialogThemeData(backgroundColor: kSurfaceContainer),
    appBarTheme: const AppBarTheme(backgroundColor: kSurfaceContainer),
    cardTheme: CardThemeData(
      color: kSurfaceContainer,
      elevation: 4,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
    ),
  );
}

/// A page transition that shows the new page immediately with no slide or
/// fade. Returning the child unwrapped makes route changes feel instant.
class _InstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

/// Lightens ([amount] > 0) or darkens ([amount] < 0) [color] by blending it
/// toward white or black. [amount] is a fraction in roughly [-1, 1].
Color _shade(Color color, double amount) {
  final target = amount < 0 ? Colors.black : Colors.white;
  return Color.lerp(color, target, amount.abs())!;
}
