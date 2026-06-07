# Draggable Shutter Button

## Problem

The shutter button position is configured via a segmented button in the settings page, offering only three fixed positions (left, center, right). This is unintuitive — the user has to leave the camera view, pick a preset, go back, and check if they like it. It also limits placement to three options when the user may want the button anywhere along the bottom of the screen.

## Proposed Solution

Replace the settings-page shutter position control with a direct drag-to-reposition flow on the camera page:

1. **Settings tile becomes a launcher**: The "Shutter button position" tile in settings navigates back to the camera page and enters a **repositioning mode**.
2. **Wiggle animation**: In repositioning mode the shutter button plays a wiggle animation, signaling that it can be dragged.
3. **Drag to reposition**: The user drags the shutter button horizontally along the bottom bar to their preferred spot.
4. **Save button**: A floating "Save" button appears at the top of the screen while in repositioning mode. Tapping it commits the new position and exits the mode.
5. **Persistence**: The position is stored as a horizontal offset (0.0–1.0, normalized to screen width) so it survives restarts and adapts to different screen sizes.

## Scope

- Replace `ShutterPosition` enum with a continuous horizontal offset.
- Add repositioning mode UI (wiggle animation, save bar, drag handling).
- Update `SettingsManager` to persist the new offset format.
- Update settings page tile to navigate + trigger reposition mode.

## Non-goals

- Vertical repositioning (the shutter stays pinned to the bottom bar).
- Multi-finger gestures or long-press to enter repositioning mode from the camera page itself (settings-only entry point for now).
- Cancel/undo — dragging back to the original spot or pressing system back suffices.
