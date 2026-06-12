# Tasks — Apply TriOS Theme

## Theme module

- [ ] Create `lib/theme/app_theme.dart` with the TriOS Starsector color constants
      (`kPrimary #49FCFF`, `kSecondary #3BCBE8`, `kSurface #0E162B`,
      `kSurfaceContainer #202941`, `kError #FC6300`, `kWarning #FDD418`,
      `kCornerRadius = 6`).
- [ ] Build the `ColorScheme` with `ColorScheme.fromSeed(seedColor: kPrimary,
      brightness: Brightness.dark)` then `copyWith` the primary/secondary/surface/error
      overrides, mirroring TriOS's dark-theme construction.
- [ ] Add the surface-container ramp (`surfaceContainerLowest/Low/High/Highest`)
      by lightening/darkening `kSurfaceContainer`, as TriOS does.
- [ ] Add `cardTheme` (color `kSurfaceContainer`, `elevation: 4`,
      `surfaceTintColor: transparent`, 6px rounded border).
- [ ] Set `scaffoldBackgroundColor`, `cardColor`, `dialogBackgroundColor` to
      `kSurfaceContainer` and `appBarTheme.backgroundColor` to `kSurfaceContainer`.
- [ ] Add the thin `sliderTheme` (thumb ~`Size(4, 20)`, `trackHeight: 4`) matching TriOS.
- [ ] Expose a single `ThemeData buildAppTheme()` entry point.

## Typography (Orbitron)

- [ ] Add the `google_fonts` dependency to `pubspec.yaml` (Option A) — or bundle the
      Orbitron `.ttf` under `assets/fonts/` and declare it (Option B).
- [ ] Apply Orbitron to title/headline text styles in the theme's `textTheme`,
      leaving body and label styles on the default font.

## Wire-up

- [ ] In `lib/main.dart`, replace the inline deepPurple `ThemeData` in `MyApp.build`
      with `theme: buildAppTheme()`.
- [ ] Confirm `MyHomePage` keeps `backgroundColor: Colors.black` (camera letterbox).
- [ ] Confirm system-UI overlay setup and routing are unchanged.

## Color sweep

- [ ] Search `lib/camera/`, `lib/gallery`, `lib/settings/`, `lib/lightning/` for
      hard-coded `Color(...)` / `Colors.*` used for UI chrome.
- [ ] Repoint chrome colors at `Theme.of(context).colorScheme` per the UI guidelines.
- [ ] Leave functional colors hard-coded (viewfinder black, strike-overlay colors)
      and add a short comment noting why each stays.

## Verify

- [ ] Check the camera page: controls drawn over live video stay readable against the
      cyan/navy chrome — add a scrim/container behind any that don't.
- [ ] Check the settings page, gallery, and lightning map render with the new palette
      (app bar, cards, sliders, switches all read from the theme).
- [ ] Confirm Orbitron renders on titles (and the body font is unaffected).
