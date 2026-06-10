# Lightning Camera

An Android camera app for catching lightning. The camera continuously buffers
frames into memory, so when a bolt strikes you've *already* captured it — open
the gallery, pick the frames you want, and save them to your device.

It also knows where the lightning is: a live strike map fed by the
[Blitzortung](https://www.blitzortung.org/) community lightning network, with
optional on-camera overlays showing each strike's real-world direction,
distance, and when its thunder will arrive.

## Features

- **Always-recording camera** — frames stream into an in-memory buffer
  (last ~100 frames) at device FPS; nothing is missed while you wait.
- **Gallery** — scroll the buffered frames, multi-select, and save to the
  device gallery as JPEG.
- **Lightning map** — live strikes near your location, with expanding
  "thunder circles" showing how far each strike's sound has travelled.
- **Strike overlay** — recent strikes drawn over the live camera feed,
  anchored to their real compass direction, with optional distance and
  thunder-arrival info per strike.
- **Mini map** — a small lightning map in the corner of the camera page.
- **Volume shutter** — hardware volume buttons trigger capture.
- **Test mode** — a built-in storm simulator for trying the map and overlays
  without a live storm.

## How it's put together

```
lib/
├── main.dart                  # entry point, GoRouter routes, theme
├── camera/                    # live feed, gallery, frame cache, YUV→RGB conversion
├── lightning/                 # map page, relay client, strike overlay, mini map,
│                              # strike→screen projection, storm simulator
├── sensors/                   # device orientation / compass service
├── settings/                  # settings page + persisted settings (signals)
├── native/                    # dart:ffi bindings to the C YUV converter
└── utils/                     # logging (Fimber wrapper)

native/yuv_converter.c         # YUV420 → RGB with rotation, compiled via CMake/NDK
relay/                         # Node websocket relay for Blitzortung data (see relay/README.md)
```

- **State management:** [signals](https://pub.dev/packages/signals) with
  top-level singletons (`imageCacheManager`, `settingsManager`,
  `lightningService`).
- **Image pipeline:** `CameraImage` (YUV420) → native C conversion with inline
  rotation via FFI → RGB image → lazy JPEG encode in an isolate.
- **Lightning data:** the app subscribes over websocket to a small relay
  (in [relay/](relay/README.md)) that holds one upstream connection to
  Blitzortung and fans strikes out to clients, filtered to a bounding box
  around each user. Blitzortung's data policy requires this server-in-the-middle
  setup, and its data is **non-commercial only** — keep anything built on this
  free.

## Getting started

Prerequisites: Flutter (the exact version is pinned in [.fvmrc](.fvmrc) /
[pubspec.yaml](pubspec.yaml) — [fvm](https://fvm.app/) is the easy way to get
it), the Android SDK, and the Android NDK for the native converter.

```bash
fvm install          # or use a matching system Flutter
fvm flutter pub get
fvm flutter run      # on a connected Android device
```

The app is Android-only. Camera, location (for the map/overlays), and photo
permissions are requested at runtime.

To use the lightning features against your own relay, run the one in
[relay/](relay/README.md) and set its `wss://` URL under Settings → custom
relay URL. Or flip on **test mode** in settings to simulate a storm locally.

## Tests

```bash
fvm flutter test
```
