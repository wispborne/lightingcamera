# Design: Add Settings Page

## Architecture

### Settings Manager (`lib/settings/settings_manager.dart`)

A top-level singleton following the same pattern as `imageCacheManager`. Uses `signals` for reactive state and `shared_preferences` for persistence.

```
final settingsManager = SettingsManager();
```

Each setting is a `signal` exposed as a getter. The manager initializes from shared_preferences on startup and writes through on every change.

```dart
enum ShutterPosition { left, center, right }

class SettingsManager {
  late final Signal<ShutterPosition> _shutterPosition;
  ShutterPosition get shutterPosition => _shutterPosition.value;

  Future<void> init() async { /* load from SharedPreferences */ }
  void setShutterPosition(ShutterPosition pos) { /* update signal + persist */ }
}
```

### Settings Page (`lib/settings/settings_page.dart`)

A standard `StatelessWidget` (or minimal `StatefulWidget`) that reads from `settingsManager` signals and calls setters on change. Uses Material `ListTile` + `SegmentedButton` for the shutter position option.

### File Layout

```
lib/settings/
├── settings_manager.dart   # singleton, signals, SharedPreferences
└── settings_page.dart       # UI
```

## Key Decisions

1. **Signals over Riverpod/Provider**: The codebase already uses `signals` exclusively. The settings manager follows the same top-level singleton + `Signal` pattern as `ImageCacheManager`.

2. **shared_preferences for persistence**: Standard Flutter choice for key-value settings. Lightweight, no schema to manage, well-maintained.

3. **Enum for shutter position**: Type-safe, easy to extend, stores as string in prefs.

4. **Left as default**: Per the requirement. The current layout centers the button, so this is a behavioral change — the default state will shift the button left.

## Integration Points

### main.dart
- Call `await settingsManager.init()` before `runApp()` (needs `WidgetsFlutterBinding.ensureInitialized()`)
- Add `/settings` GoRoute using existing `Pages.settings` name

### camera_page.dart
- Add gear icon to the top bar area (top-right of the overlay, matching the existing style)
- Read `settingsManager.shutterPosition` to position the shutter button via `MainAxisAlignment` in the bottom `Row`:
  - `left` → `MainAxisAlignment.start` with padding
  - `center` → `MainAxisAlignment.center`
  - `right` → `MainAxisAlignment.end` with padding

### pubspec.yaml
- Add `shared_preferences` dependency
