# Tasks: Camera Strike Overlay

## 1. Orientation sensor

- [x] Add a fused-orientation sensor package to `pubspec.yaml` (try `flutter_rotation_sensor`; fall back to `sensors_plus` if it fails to build) and run `flutter pub get`
- [x] Create `lib/sensors/orientation_service.dart`: subscribe to the rotation vector, expose the device→world rotation matrix as a `signal`, throttle (~50 Hz game interval) and lightly smooth via quaternion blending
- [ ] Verify on-device that heading tracks compass and pitch/roll respond correctly (log values while rotating the phone) — *needs device*

## 2. Camera field of view

- [x] Add an Android method channel (sibling to the volume-keys one) that returns horizontal FOV in degrees via `Camera2` (`SENSOR_INFO_PHYSICAL_SIZE` + `LENS_INFO_AVAILABLE_FOCAL_LENGTHS`)
- [x] Dart side: read the FOV on camera init; fall back to ~65° if the query fails; derive vertical FOV from the preview aspect ratio

## 3. Projection math (pure, testable)

- [x] Create `lib/lightning/strike_projection.dart`: given user `LatLng`, strike `LatLng`, the device→world rotation matrix, FOV, and screen size, return either on-screen `(x, y)` or an off-screen edge direction
- [x] Implement bearing via `latlong2`, transform the strike's world direction into the device frame, perspective-divide for screen placement (roll handled implicitly by the matrix)
- [x] Implement edge-arrow placement: project off-screen strikes to the nearest screen border with a pointing angle
- [x] Add unit tests for the projection (strike dead-ahead, behind, to the side, tilted horizon) — *7 tests passing*

## 4. Enable/disable setting

- [x] Add a persisted `strikeOverlayEnabled` signal to `settings_manager.dart` (getter, `setStrikeOverlayEnabled`, `shared_preferences` key — mirror `showThunderCircles`); default **off**
- [x] Add a `SwitchListTile` to `settings_page.dart` for the overlay, matching the existing "Lightning test mode" tile
- [x] Add a round toggle button to the camera page's right-hand button column (below settings/map; `center_focus_strong/weak` icon) which calls `setStrikeOverlayEnabled(!current)`
- [x] Confirm both controls stay in sync via the shared signal (both read/write `strikeOverlayEnabledSignal`)

## 5. Overlay controller

- [x] Create `lib/lightning/strike_overlay_controller.dart`: hold the GPS fix, FOV, and orientation subscription (placement computed in the widget where the live `Size` is known)
- [x] Gate all work on `strikeOverlayEnabled`: start GPS + orientation + service connection only when on; tear them down when it flips off (zero sensor/GPS work when disabled)
- [x] Resolve GPS via `geolocator` (reuse the map page's permission logic) and connect `lightningService` with that center
- [x] Coordinate the shared `lightningService` lifecycle so the camera and map pages don't disconnect each other (ref-counted `acquire`/`release`; map page migrated)

## 6. Overlay widget

- [x] Create `lib/lightning/strike_overlay.dart`: a transparent `Watch` widget drawing in-place markers (age color/opacity matching the map) and edge arrows
- [x] Roll is handled implicitly — the device→world matrix already encodes it, so circular markers stay world-anchored and edge arrows point along the computed screen angle
- [x] Hide the overlay entirely when disabled, or when location or orientation is unavailable

## 7. Wire into the camera page

- [x] Insert the overlay into the `Stack` above `CameraPreview` but below the HUD/controls (wrapped in `IgnorePointer`) so buttons stay tappable
- [x] Start GPS + orientation + service connection on `didPush` / `didPopNext` (only when enabled); tear down on `didPushNext` / `didPop` / `dispose`
- [x] Ensure overlay teardown matches the existing camera pause/resume lifecycle (`_syncOverlay` on every visibility change + app background; effect-driven on setting change)

## 8. Permissions & verification

- [x] Confirm location permission is present (`ACCESS_FINE/COARSE_LOCATION` in the manifest); `geolocator` requests at runtime in the controller
- [ ] Test in lightning test mode (`settingsManager.lightningTestMode`) so simulated strikes can be aimed at without a live storm — *needs device*
- [ ] Verify toggling the overlay off from both the settings page and the camera button stops all sensor/GPS work and clears the overlay — *needs device*
- [ ] On-device check: markers stay world-anchored while panning; off-screen strikes show edge arrows that resolve into markers when faced; feed/caching/shutter unaffected — *needs device*
