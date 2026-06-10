# Design: Camera Strike Overlay

## Overview

A transparent overlay sits on top of `CameraPreview` in `camera_page.dart`. Every frame (or
on every sensor tick) it asks one question per strike: *given where the user is, where this
strike is, and where the phone is pointing, where on screen does this strike belong?* The
answer is either an (x, y) inside the viewfinder (draw a marker) or "off-screen in direction
θ" (draw an edge arrow).

The strike data already exists (`lightningService.strikes`). The only genuinely new pieces
are (1) the phone's real-world orientation, (2) the user's GPS position on the camera page,
and (3) the projection math that ties them together.

## Inputs

| Input | Source | Notes |
|---|---|---|
| Strikes (`LatLng`, `time`) | `lightningService.strikes` (existing signal) | take 5 newest |
| User location (`LatLng`) | `geolocator` (existing dep) | one fix, refreshed slowly |
| Phone heading / pitch / roll | **new** orientation sensor stream | the fusion problem |
| Camera horizontal & vertical FOV | camera plugin / platform | needed to map angle→pixels |

## Key Decisions

### 1. Orientation source: fused absolute orientation, not raw compass

Placing a marker needs all three angles:
- **azimuth** (compass heading) — which way is the back of the phone pointing,
- **pitch** — tilt up/down, sets the horizon's vertical position on screen,
- **roll** — twist about the view axis, rotates the overlay so markers track the horizon.

Raw magnetometer + accelerometer are noisy and need fusing. Android exposes a fused
`TYPE_ROTATION_VECTOR` (a quaternion combining compass, accelerometer, and gyro) that is
exactly what AR needs. We will add a sensor package that surfaces this — preferred:
`flutter_rotation_sensor` (exposes azimuth/pitch/roll + quaternion from the rotation vector);
fallback candidate `sensors_plus` (`magnetometer` + `accelerometer`, fused in-app) if the
former proves unmaintained on the current Flutter/Gradle setup. The package choice is the
first task and is verified before the math is built on top of it.

The sensor stream is throttled (e.g. ~30 Hz) and smoothed lightly to avoid jitter, then
exposed as a signal so the overlay rebuilds reactively, matching the app's `signals` pattern.

### 2. FOV: query the camera, fall back to a default

The projection converts an angular offset into a pixel offset, which requires the camera's
field of view. We try to read it from the platform first:
- Android `Camera2` exposes `SENSOR_INFO_PHYSICAL_SIZE` + `LENS_INFO_AVAILABLE_FOCAL_LENGTHS`,
  from which horizontal FOV = `2 * atan(sensorWidth / (2 * focalLength))`. The `camera`
  plugin does not surface this, so we read it via a small platform channel (the project
  already uses one for volume keys — `com.wisp.lightingcamera/volume_keys`; we add a sibling
  method channel, e.g. `.../camera_info`, returning the FOV in degrees).
- If the platform query fails, fall back to a sensible default (~65° horizontal) so the
  overlay still works, just slightly less precisely. Vertical FOV is derived from horizontal
  FOV and the preview aspect ratio.

This keeps the chosen "query from camera" approach but never lets a missing value break the
feature.

### 3. Projection model: strikes live on the horizon

Strikes are far away and ground-level, so we treat each as sitting on the horizon at its
real-world bearing (elevation ≈ 0).

**Implementation refinement:** rather than the scalar azimuth/pitch/roll formulas originally
sketched here, the implemented `projectStrike` works directly from the device→world rotation
matrix. This is cleaner *and* avoids gimbal lock — the euler azimuth describes where the
phone's *top* points, which is undefined when the phone is held vertically like a camera. The
matrix folds heading, tilt, and roll into one transform:

1. `bearing` from user → strike via a haversine bearing helper (`latlong2` `LatLng` in).
2. Strike world direction on the horizon: `(sin·bearing, cos·bearing, 0)` (East, North, Up).
3. Transform that into the device frame with `dev = Rᵀ · world`.
4. The camera looks down device −Z. If `dev.z < 0` it's in front: perspective-divide
   (`u = dev.x/−dev.z`, `v = dev.y/−dev.z`), normalize by `tan(FOV/2)`, and if `|nx|,|ny| ≤ 1`
   it's on-screen at the matching pixel. Roll is already baked into the matrix, so circular
   markers stay world-anchored with no extra rotation step.
5. Otherwise it's off-screen → edge arrow: clamp the screen-space direction to the screen-edge
   box and point the arrow outward along it. Strikes behind the camera (`dev.z ≥ 0`) use the
   in-plane `(dev.x, dev.y)` direction to choose the shorter way to turn.

`vFov` is derived in the widget from `hFov` and the live view aspect:
`vFov = 2·atan(tan(hFov/2) · height/width)`. Covered by unit tests in
`test/strike_projection_test.dart`.

### 4. Enable/disable: one persisted setting, two controls

A single `strikeOverlayEnabled` flag lives in `settingsManager` as a persisted `signal`
(same pattern as `lightningTestMode` / `showThunderCircles`: backed by `shared_preferences`,
exposed as `…Signal` + getter + `set…`). Both UI controls read and write this one signal:

- **Settings page**: a `SwitchListTile` in a `Watch`, identical in shape to the existing
  "Lightning test mode" tile.
- **Camera page**: a round toggle button in the existing right-hand button column (below the
  settings and map buttons, e.g. at `top: topInset + 104`). Its icon reflects on/off state
  (e.g. filled vs. outlined `Icons.bolt` / a dedicated AR icon) and tapping it calls
  `settingsManager.setStrikeOverlayEnabled(!current)`.

Because both controls bind to the same signal, they stay in sync automatically via `signals`.
The overlay controller only starts its GPS fix and orientation subscription when the flag is
on, and tears them down when it flips off — so "off" means zero sensor/GPS work, not just a
hidden widget.

### 5. Where the overlay lives and how it connects

- The camera page gains a lightweight controller/helper (e.g. `StrikeOverlayController`) that
  owns: the orientation subscription, the GPS fix, the FOV value, and a computed list of
  "placed strikes" (marker-or-arrow + screen coords). Exposed via `signals` so the widget is a
  `Watch`.
- On `camera_page` becoming visible (`didPush` / `didPopNext`), resolve GPS and call
  `lightningService.connect(center)` — reusing the exact path the map uses, including test
  mode. On leaving (`didPushNext` / `didPop` / dispose), stop the orientation subscription.
  Disconnect from the relay is coordinated so we don't fight the map page over the shared
  singleton (only disconnect if the map isn't also using it; simplest: connect on demand and
  let the existing display window prune — see Risks).
- The overlay `Stack` child is inserted above `CameraPreview` but below the existing HUD/
  controls so buttons stay tappable.

## Files

| File | Change |
|---|---|
| `pubspec.yaml` | add orientation sensor package |
| `lib/sensors/orientation_service.dart` | **new** — fused azimuth/pitch/roll as signals |
| `lib/lightning/strike_overlay_controller.dart` | **new** — fuses location + orientation + FOV + strikes into placed-strike list |
| `lib/lightning/strike_projection.dart` | **new** — pure math: bearing/Δaz/pitch → screen x/y or edge direction (unit-testable) |
| `lib/lightning/strike_overlay.dart` | **new** — the transparent `Widget` drawing markers + edge arrows |
| `lib/camera/camera_page.dart` | wire overlay into the `Stack`; resolve GPS + connect service on show; teardown on hide; add overlay toggle button |
| `lib/settings/settings_manager.dart` | add persisted `strikeOverlayEnabled` signal (getter + setter, `shared_preferences` key) |
| `lib/settings/settings_page.dart` | add a `SwitchListTile` for the overlay, matching the test-mode tile |
| `android/.../MainActivity` + new method channel | **new** — return camera FOV in degrees |

## Risks / Open Points

- **Compass accuracy**: magnetometers drift and need figure-8 calibration; nearby metal/
  magnets skew heading. Markers may sit several degrees off. Acceptable for "which way to
  point," and the rotation-vector fusion is the best available mitigation.
- **Shared `lightningService` lifecycle**: both the map and the camera now connect/disconnect
  the singleton. Naive disconnect on either page's dispose could cut the other off. Mitigation:
  reference-count connections, or have the camera only `connect` if not already connected and
  never force-disconnect. Decide during implementation; keep it simple.
- **FOV correctness for the preview**: the sensor FOV is the full-sensor FOV, but the preview
  may be cropped to fit the screen (`BoxFit.cover`). The effective FOV must account for the
  crop between `previewSize` and the rendered area, or markers drift near the edges.
- **Battery / heat**: continuous camera stream + sensors + GPS. GPS uses a single/low-rate
  fix (storms move slowly); sensors are throttled.
