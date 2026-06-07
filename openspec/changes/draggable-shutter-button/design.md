# Design: Draggable Shutter Button

## Overview

Replace the discrete 3-position shutter placement with a continuous horizontal offset, repositioned via drag directly on the camera page.

## Data Model Changes

### SettingsManager

- Remove `ShutterPosition` enum.
- Replace with `double shutterOffsetX` — a value from `0.0` (left edge + padding) to `1.0` (right edge - padding). Default: `0.5` (centered behavior would change from current default of `left`, but `0.0` preserves the current default).
- Default value: `0.0` (matches current default of `ShutterPosition.left`).
- SharedPreferences key: `shutter_offset_x` (new key; old `shutter_position` key is ignored).
- Signal: `Signal<double> _shutterOffsetX` exposed as `ReadonlySignal<double> shutterOffsetXSignal`.

### Repositioning Mode

- New `Signal<bool> _isRepositioning` on `SettingsManager` (not persisted — runtime only).
- Exposed as `ReadonlySignal<bool> isRepositioningSignal`.
- Methods: `enterRepositionMode()`, `exitRepositionMode()`.

## Camera Page Changes

### Shutter Button Positioning

Replace the `Row` + `MainAxisAlignment` approach with a `Positioned` widget inside the existing `Stack`:

```
Positioned(
  bottom: 50,
  left: (screenWidth - buttonWidth) * offsetX,
  child: shutterButton,
)
```

Where `offsetX` is the `shutterOffsetXSignal` value clamped to keep the button fully on-screen (accounting for padding).

### Repositioning Mode UI

When `isRepositioningSignal` is `true`:

1. **Wiggle animation**: Apply a `RotationTransition` (or `AnimatedBuilder` with sine-wave rotation) to the shutter button — small ±5° oscillation at ~2Hz. Use a repeating `AnimationController`.

2. **Drag handling**: Wrap the shutter button in a `GestureDetector` with `onHorizontalDragUpdate` (only active in reposition mode). Update a local drag offset in real time; on drag end, write to `settingsManager.setShutterOffsetX()`.

3. **Save bar**: A `Positioned` bar at the top with a "Save position" button. Tapping it calls `settingsManager.exitRepositionMode()` and persists the current offset. Visually: semi-transparent dark bar with a pill-shaped save button.

4. **Shutter tap disabled**: In repositioning mode, tapping the shutter button does NOT open the gallery.

### Navigation Flow

From settings → tap "Shutter button position" tile:
1. Call `settingsManager.enterRepositionMode()`.
2. Call `context.go('/')` (pop back to camera page).
3. Camera page sees `isRepositioning == true` and shows the repositioning UI.

## Settings Page Changes

Replace `_ShutterPositionTile`'s segmented button with a simple `ListTile` that has a trailing arrow icon and subtitle text like "Tap to reposition". On tap, it triggers the navigation flow above.

## File Changes

| File | Change |
|------|--------|
| `lib/settings/settings_manager.dart` | Replace enum + signal with double offset + reposition mode signal |
| `lib/camera/camera_page.dart` | New positioning logic, wiggle animation, drag handling, save bar |
| `lib/settings/settings_page.dart` | Replace segmented button with navigation tile |

## Edge Cases

- **Screen rotation**: The 0.0–1.0 normalized offset naturally adapts to width changes.
- **Back button during reposition**: `exitRepositionMode()` without saving — position reverts to last persisted value. Actually, simpler: always save on drag end, so the save button just exits the mode.
- **First launch**: Default offset `0.0` places button at left edge, matching current `ShutterPosition.left` default.
