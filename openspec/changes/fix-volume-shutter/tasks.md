# Tasks: Fix Volume Shutter

- [x] Override `onKeyDown` in `MainActivity.kt` to intercept `KEYCODE_VOLUME_UP` / `KEYCODE_VOLUME_DOWN` and send events via `MethodChannel("com.wisp.lightingcamera/volume_keys")`
- [x] Add `MethodChannel` listener in `CameraPageState.initState` that triggers `_onShutterPressed()` on volume key events
- [x] Add 300ms debounce via `_lastShutterTime` timestamp check
- [x] Gate the channel handler on `_volumeButtonsEnabled && _isPageVisible`
- [x] Simplify `_enableVolumeButtonOverride` / `_disableVolumeButtonOverride` to only toggle the `_volumeButtonsEnabled` flag
- [x] Remove all `VolumeController` logic: listener, `_originalVolume`, `_isVolumeControllerInitialized`, `showSystemUI` calls, `_initializeVolumeController()`
- [x] Remove `volume_controller` from `pubspec.yaml` and run `flutter pub get`
- [ ] Test: volume button triggers shutter when volume is at 0%, 50%, and 100%
- [ ] Test: rapid presses only trigger once per 300ms window
- [ ] Test: system volume slider does NOT appear when pressing volume buttons
- [ ] Test: volume buttons are inactive on gallery page and re-activate on return
