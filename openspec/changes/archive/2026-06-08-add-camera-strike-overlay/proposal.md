# Add Camera Strike Overlay

## Problem

The app now knows where lightning is striking (the `/map` page plots real strikes from
the relay), but that knowledge lives on a separate top-down map. While the camera is open
— the moment the user is actually trying to catch a strike — they get no help knowing
*which way to point the phone*. They have to mentally translate a bird's-eye map into a
real-world direction, then guess, then look up. The map and the viewfinder are two
disconnected views of the same storm.

## Proposed Solution

Overlay the recent lightning strikes directly on the live camera feed, anchored to the
real world. Using the user's GPS location plus the phone's compass and motion sensors, we
compute the real-world direction (bearing) of each strike and draw a marker at the matching
spot in the viewfinder. As the user sweeps the phone around, the markers stay pinned to
their real-world positions — turn toward a strike and its marker slides to center; turn
away and it slides off.

```
 GPS location ─┐
               ├─▶ bearing + distance to each strike ─┐
 strike LatLng ┘                                       ├─▶ screen x/y in viewfinder
 compass heading ─┐                                    │   (marker or edge arrow)
 pitch / roll ────┴─▶ where the phone is pointing ─────┘
```

- Show the **last 5 strikes** (most recent by time).
- A strike inside the current field of view draws as an **in-place marker** over the feed,
  styled like the map markers (age-faded, color by age).
- A strike outside the view draws as an **edge arrow** pinned to the screen border,
  pointing the way the user should turn to bring it into view.

## Scope

- **Sensor fusion**: read the phone's absolute orientation (compass heading / azimuth,
  pitch, roll) so we know where the camera is pointing in the real world.
- **GPS on the camera page**: reuse `geolocator` to get the user's location and feed it to
  the existing `lightningService` so strikes are available while the camera is open.
- **Projection math**: convert each strike's real-world bearing + the phone's orientation
  into a screen position, using the camera's field of view.
- **Overlay widget**: a transparent layer over `CameraPreview` that draws the 5 markers
  and edge arrows, updating in real time as orientation changes.
- **On/off control**: a persisted setting (settings page toggle) plus a quick toggle button
  on the camera page itself. Both drive the same setting so they stay in sync. When off, no
  sensors/GPS work runs and nothing is drawn.

## Non-Goals

- **Elevation accuracy / 3D placement** — strikes are treated as sitting on the horizon
  line (distant, ground-level). No attempt to place them above/below horizon by altitude.
- **Auto-triggering the shutter** when a strike enters the frame — still out of scope, same
  reasoning as the map change (cache window vs. feed delay).
- **Distance/ETA labels or thunder timing** on the overlay — keep it to direction only; the
  map remains the place for richer detail.
- **iOS** — Android only, consistent with the rest of the app.
- **Replacing the map** — the overlay complements the existing `/map` page; both stay.
