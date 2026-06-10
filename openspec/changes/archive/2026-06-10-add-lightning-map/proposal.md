# Add Lightning Map

## Problem

The app helps users photograph lightning, but gives no help knowing *where* lightning
is happening. A user has to guess which direction to point the phone and when a storm
is approaching. There's no awareness of real-world strike activity around them.

## Proposed Solution

Add a live map that shows recent real lightning strikes near the user, sourced from the
[Blitzortung.org](https://www.blitzortung.org/) community lightning network. The map
centers on the user's GPS location and plots each strike as a marker that fades with age,
so the user can see where activity is and which way it's drifting — and aim the phone
accordingly.

Because Blitzortung's data policy requires third-party apps to serve data from their own
server (and prohibits commercial use), strikes are relayed through a small **relay service
running on the user's own VPS**. The relay holds one upstream connection to Blitzortung,
decodes the feed, filters strikes to a bounding box around the user, and forwards them to
the app over a websocket.

```
 Blitzortung WS ──▶ [ relay on user's VPS ] ──▶ Flutter app (flutter_map)
   one upstream         decode + filter             strikes fade by age,
   {"a":111}            to user's box               centered on GPS
```

## Scope

- **Relay service** (separate from the Flutter app): connects to Blitzortung's websocket,
  decodes the feed, filters strikes to a client-supplied bounding box, and re-broadcasts
  over a websocket. Deployed to the user's existing VPS.
- **GPS location** in the app via `geolocator` (new runtime permission).
- **New `/map` route** with a `flutter_map` + OpenStreetMap view, centered on the user,
  plotting strikes as age-faded markers.
- **Navigation** to the map from the camera page (alongside the existing gallery and
  settings entry points).

## Non-Goals

- **Compass / "point this way" guidance** — no magnetometer arrow fusing strike bearing
  with phone heading. The top-down map only. (Possible later.)
- **Storm-approach prediction** — no clustering, motion vectors, or ETA. Strikes fade by
  age and motion reads visually; no math. (Possible later.)
- **Auto-triggering the camera shutter** from strike data — out of scope; the cache
  buffer is too short for the feed's delay and that's a different feature.
- **Commercial lightning APIs** (Xweather, Earth Networks, DTN) — not needed for a
  personal, non-commercial app.
- **Strike history / persistence** — the map shows a live rolling window only.
