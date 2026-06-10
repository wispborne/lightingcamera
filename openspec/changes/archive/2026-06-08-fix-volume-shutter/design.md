# Design: Fix Volume Shutter

## Approach

The root cause is that detecting volume *level changes* is inherently unreliable as a proxy for volume *button presses*. The fix is to intercept the key events at the native Android level before the system processes them.

Flutter's Dart-side key event system (`HardwareKeyboard`, `SystemChannels.keyEvent`) cannot be used due to [flutter#71144](https://github.com/flutter/flutter/issues/71144) — volume keys aren't delivered to Dart until a TextField has been focused.

## Native Key Interception

Override `onKeyDown` in `MainActivity.kt` to intercept `KEYCODE_VOLUME_UP` and `KEYCODE_VOLUME_DOWN`. Returning `true` consumes the event at the Activity level, before `PhoneWindow` can trigger the volume change or show the system volume slider.

Send the event to Dart via a `MethodChannel` named `com.wisp.lightingcamera/volume_keys`.

```kotlin
// MainActivity.kt
override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
    if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
        flutterEngine?.dartExecutor?.binaryMessenger?.let {
            MethodChannel(it, "com.wisp.lightingcamera/volume_keys")
                .invokeMethod("volumeKeyPressed",
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down")
        }
        return true
    }
    return super.onKeyDown(keyCode, event)
}
```

## Dart Side

In `CameraPageState`, set up a `MethodChannel` listener in `initState` that calls `_onShutterPressed()` when a volume key event arrives.

The channel handler checks `_volumeButtonsEnabled && _isPageVisible` before triggering, same as today.

## Debounce

Add a `DateTime? _lastShutterTime` field. In the channel handler, skip if less than 300ms have elapsed since the last trigger. This prevents:
- Double-fires from a single physical press
- Continuous-fire from holding the button

## Lifecycle Integration

The existing `_isPageVisible` / `_volumeButtonsEnabled` flags remain. The `_enableVolumeButtonOverride` / `_disableVolumeButtonOverride` methods simplify to just toggling `_volumeButtonsEnabled` — no more `showSystemUI` management or volume level storage needed since the native override prevents volume changes entirely.

Note: The native `onKeyDown` override is always active while the Activity exists. The Dart side gates whether to act on it. This means volume buttons won't change system volume while the app is in the foreground — acceptable for a camera app.

## File Changes

| File | Change |
|------|--------|
| `android/.../MainActivity.kt` | Override `onKeyDown` to intercept volume keys, send via MethodChannel |
| `lib/camera/camera_page.dart` | Replace `VolumeController` listener with `MethodChannel` listener, add debounce, remove volume restore logic |
| `pubspec.yaml` | Remove `volume_controller` dependency |

## Risks

- Volume buttons won't change system volume while the app is foregrounded. This is intentional for a camera app but worth noting.
- If a device OEM overrides volume key handling at the system/framework level (very rare), the `onKeyDown` override won't fire. The on-screen shutter button remains as fallback.
