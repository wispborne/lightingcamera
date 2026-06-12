# Apply TriOS Theme

## Problem

Lightning Camera currently uses a default Material theme seeded from `deepPurple`
(`lib/main.dart`). It looks generic and has no relationship to the storm-watching
purpose of the app. The companion project TriOS has a polished, recognizable
"Starsector" look — a dark sci-fi/HUD style with a bright cyan accent on deep navy
surfaces — that reads well for a dark-sky, night-shooting tool. The app already
half-aligns with it: the adaptive launcher icon background is `#0E162B`, which is
exactly TriOS's surface color.

## Solution

Port the TriOS "Starsector" visual style into Lightning Camera as the app's single
theme. Specifically:

- **Palette:** bright cyan primary `#49FCFF`, lighter cyan secondary `#3BCBE8`,
  deep navy surface `#0E162B`, navy `#202941` for cards/containers — built with
  Material 3 `ColorScheme.fromSeed` from the cyan, the same way TriOS constructs it.
- **Typography:** Orbitron for titles and headers (the TriOS display font), with the
  default body font for everything else.
- **Component styling:** 6px corner radius, low-elevation cards with a transparent
  surface tint, a thin slider thumb, an orange error color, and a gold warning color
  — matching TriOS's `ThemeManager` defaults.
- Centralize all of this in one theme module instead of the inline `ThemeData` in
  `main.dart`, so the rest of the app keeps pulling colors and text styles from
  `Theme.of(context)`.

The camera viewfinder keeps its black letterbox background — that is a functional
choice (it reads as a viewfinder), not theme-colored space, so the theme change must
not touch it.

## Scope

- A new theme module that produces the TriOS-styled `ThemeData`.
- Wire it into `MaterialApp.router` in `main.dart`.
- Add the Orbitron font (via `google_fonts` or a bundled asset).
- Apply Orbitron titles to existing app bars / page headers where appropriate.
- Adjust any place currently hard-coding a color so it reads from `colorScheme`
  instead (per the project UI guidelines).

## Non-Goals

- No runtime theme switcher or multiple selectable themes — TriOS supports many
  themes, but here we ship the single Starsector look.
- No light theme.
- No changes to camera, gallery, lightning-detection, or map behavior — visual only.
- No port of TriOS's full semantic-color system (success/info/neutral) beyond the
  error and warning colors actually used by the app.
