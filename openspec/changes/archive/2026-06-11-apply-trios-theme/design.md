# Design — Apply TriOS Theme

## Approach

Recreate the relevant slice of TriOS's `ThemeManager.convertToThemeData` as a small,
self-contained theme module in Lightning Camera. We do **not** copy TriOS's full
machinery (Riverpod notifier, JSON theme loading, semantic-color generator, palette
extraction). We only need the one fixed Starsector dark theme, so the module is a
plain function returning a `ThemeData`.

## Source of truth (from TriOS)

The Starsector swatch in TriOS (`theme_manager.dart` → `StarsectorTriOSTheme`):

| Role               | Value                         | Hex       |
|--------------------|-------------------------------|-----------|
| primary            | `RGBO(73, 252, 255, 1)`       | `#49FCFF` |
| secondary          | `RGBO(59, 203, 232, 1)`       | `#3BCBE8` |
| surface            | `RGBO(14, 22, 43, 1)`         | `#0E162B` |
| surfaceContainer   | `RGBO(32, 41, 65, 1)`         | `#202941` |
| error              | `ARGB(255, 252, 99, 0)`       | `#FC6300` |
| warning            | `ARGB(255, 253, 212, 24)`     | `#FDD418` |
| corner radius      | `6`                           | —         |
| title font         | `Orbitron`                    | —         |

These are the exact constants from `constants_theme.dart` and the `StarsectorTriOSTheme`
class, so the look matches the source project.

## Key decisions

### 1. New file: `lib/theme/app_theme.dart`

Exposes `ThemeData buildAppTheme()` (and the raw color constants as named values so
other widgets can reference them directly if needed). Internally it mirrors TriOS:

```dart
final scheme = ColorScheme.fromSeed(
  seedColor: kPrimary,            // #49FCFF
  brightness: Brightness.dark,
).copyWith(
  primary: kPrimary,
  secondary: kSecondary,
  surface: kSurface,              // #0E162B
  error: kError,                  // #FC6300
);
```

Then `ThemeData(useMaterial3: true, colorScheme: scheme, ...)` with:
- `scaffoldBackgroundColor` / `cardColor` / `dialogBackgroundColor` = `kSurfaceContainer`
- `cardTheme`: color `kSurfaceContainer`, `elevation: 4`, `surfaceTintColor: transparent`,
  `RoundedRectangleBorder(6)`
- `appBarTheme.backgroundColor` = `kSurfaceContainer`
- a thin `sliderTheme` (thumb ~`Size(4, 20)`, `trackHeight: 4`) like TriOS's
- the surface-container ramp (`surfaceContainerLow/High/...`) derived by lightening
  and darkening `kSurfaceContainer`, matching TriOS's dark-theme `copyWith`

### 2. Typography — Orbitron for titles only

TriOS uses Orbitron as a named family for headers and a normal body font elsewhere.
Two viable ways to get Orbitron:

- **Option A (preferred): `google_fonts` package.** Add the dependency and build the
  text theme with `GoogleFonts.orbitronTextTheme(...)` applied to the title styles
  (`titleLarge`, `titleMedium`, `headlineSmall`, etc.) while leaving body styles on
  the default font. Matches how TriOS pulls fonts from Google Fonts and needs no
  bundled asset.
- **Option B: bundle the Orbitron `.ttf`** under `assets/fonts/` and declare it in
  `pubspec.yaml`. No network/cache dependency, but adds binary assets to the repo.

We go with **Option A** unless offline-only builds are a hard requirement. The title
styles get `fontFamily: Orbitron`; body/label styles stay default.

### 3. Wire into `main.dart`

Replace the inline `ThemeData(colorScheme: ColorScheme.fromSeed(... deepPurple ...))`
in `MyApp.build` with `theme: buildAppTheme()`. Leave `MaterialApp.router`, routing,
and system-UI overlay setup untouched. `MyHomePage`'s `backgroundColor: Colors.black`
stays — it is the camera letterbox, not theme surface.

### 4. Replace hard-coded colors

Sweep the existing pages (`camera_page.dart`, `gallery_page.dart`, `settings_page.dart`,
`lightning_map_page.dart`, overlays) for hard-coded `Color(...)` / `Colors.*` used for
UI chrome and repoint them at `Theme.of(context).colorScheme` per the project's UI
guidelines. **Exception:** genuinely functional colors stay hard-coded — the black
viewfinder letterbox, and any lightning-strike overlay colors that must stay legible
over arbitrary camera frames. Note each exception rather than theming it blindly.

## Files changed

| File                         | Change                                                        |
|------------------------------|---------------------------------------------------------------|
| `lib/theme/app_theme.dart`   | **New.** `buildAppTheme()` + color constants.                 |
| `lib/main.dart`              | Use `buildAppTheme()` instead of the deepPurple inline theme. |
| `pubspec.yaml`               | Add `google_fonts` (Option A) or bundle Orbitron (Option B).  |
| `lib/camera/*`, `settings/*`, `lightning/*` | Repoint chrome colors to `colorScheme` where hard-coded. |

## Risks / trade-offs

- **Contrast over live video.** Cyan-on-navy chrome sits on top of camera frames.
  Controls already drawn over the preview may need a scrim or container behind them so
  they stay readable — check the camera overlay specifically.
- **`google_fonts` first-run fetch.** Orbitron is downloaded and cached on first use;
  a cold offline launch shows the fallback font briefly. Option B avoids this if it
  matters.
- **Don't over-theme functional colors.** The viewfinder black and strike-overlay
  colors are intentional; theming them would regress legibility.
