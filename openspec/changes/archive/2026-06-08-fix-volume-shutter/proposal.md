# Fix Volume Shutter Reliability

## Problem

The volume buttons don't reliably trigger photo capture. The current implementation uses `volume_controller`'s volume-change listener to detect button presses, which has several failure modes:

1. **Dead at volume boundaries**: If device volume is at 0% or 100%, pressing volume-down or volume-up (respectively) produces no change event — the shutter silently fails.
2. **Async volume restoration race**: After a press, `setVolume(_originalVolume)` restores volume asynchronously without being awaited. Rapid presses can land before restoration completes, causing missed or duplicate triggers.
3. **No debounce**: A single physical press can fire multiple change events on some Android devices, and holding the button fires continuously. There's no guard against this.
4. **System volume UI still appears**: `showSystemUI = false` only affects programmatic `setVolume()` calls — it does NOT suppress the system volume slider when physical buttons are pressed.

## Proposed Solution

Replace the volume-change listener with a native Android `onKeyDown` override in `MainActivity.kt`. This intercepts the actual key press at the Activity level — before Android's `PhoneWindow` processes it — and sends it to Dart via a platform `MethodChannel`.

Returning `true` from `onKeyDown` for `KEYCODE_VOLUME_UP/DOWN` reliably:
- Prevents the system volume from changing
- Suppresses the system volume slider UI
- Works regardless of current volume level

This is the same pattern used by Google Camera and other Android camera apps.

**Why not `HardwareKeyboard`?** Flutter has an open bug ([#71144](https://github.com/flutter/flutter/issues/71144), P3) where volume key events are never delivered to Dart key handlers on Android until a `TextField` gains focus. Since this is a camera app with no text fields, volume keys would never arrive via `HardwareKeyboard`.

## Scope

- `android/.../MainActivity.kt` — override `onKeyDown`, send volume events via MethodChannel
- `lib/camera/camera_page.dart` — replace `VolumeController` listener with MethodChannel listener, add debounce
- `pubspec.yaml` — remove `volume_controller` dependency

## Non-Goals

- Changing shutter behavior (still opens gallery).
- Supporting other hardware buttons (e.g., power button).
- iOS support.
