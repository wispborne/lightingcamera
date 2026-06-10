# Tasks: Draggable Shutter Button

## Data model

- [x] Replace `ShutterPosition` enum with `double shutterOffsetX` (0.0–1.0) in `SettingsManager`
- [x] Add `shutter_offset_x` SharedPreferences key, remove old `shutter_position` key usage
- [x] Add `isRepositioning` signal and `enterRepositionMode()`/`exitRepositionMode()` methods to `SettingsManager`

## Camera page — positioning

- [x] Replace `Row`/`MainAxisAlignment` shutter layout with `Positioned` widget using the offset signal
- [x] Compute `left` position from `shutterOffsetX * (screenWidth - buttonWidth - padding)`

## Camera page — repositioning mode

- [x] Add wiggle animation (repeating ±5° rotation) that activates when `isRepositioning` is true
- [x] Add `GestureDetector` with horizontal drag handling to update offset in real time during reposition mode
- [x] Persist offset via `setShutterOffsetX()` on drag end
- [x] Disable shutter tap (gallery open) while in reposition mode
- [x] Show save bar at top with "Save position" button that calls `exitRepositionMode()`

## Settings page

- [x] Replace `_ShutterPositionTile` segmented button with a `ListTile` that navigates to camera page and enters reposition mode

## Cleanup

- [x] Remove `ShutterPosition` enum and all references
- [ ] Test: drag to edges, restart app and verify position persists, verify shutter tap works normally outside reposition mode
