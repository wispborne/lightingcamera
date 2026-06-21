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

## Installing with Obtainium

[Obtainium](https://github.com/ImranR98/Obtainium) installs the app straight
from this repo's [GitHub releases](https://github.com/wispborne/lightningcamera/releases)
and keeps it updated — no app store needed.

**Quickest way:** in Obtainium, tap **Add App** and paste the repo URL:

```
https://github.com/wispborne/lightningcamera
```

Releases are split by CPU architecture, so each one carries several APKs. Leave
Obtainium's **"Try to filter APKs by CPU architecture"** setting on (it's on by
default) and it picks the right one for your phone automatically. If you ever
need to force it, set the APK filter to `arm64-v8a` (most modern phones).

**Or import a ready-made profile:** save the JSON below to a file and use
Obtainium's **Import/Export → Import from JSON**.

```json
{
  "id": "com.wisp.lightingcamera",
  "url": "https://github.com/wispborne/lightningcamera",
  "author": "wispborne",
  "name": "Lightning Camera",
  "preferredApkIndex": 0,
  "additionalSettings": "{\"autoApkFilterByArch\":true,\"fallbackToOlderReleases\":true}",
  "overrideSource": "GitHub"
}
```

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

## Building a release APK

Release builds are split by CPU architecture, so each APK only carries the
native code for one type of phone (smaller downloads). Pick the architecture
with `--target-platform`:

```bash
# 64-bit phones (everything from the last several years)
fvm flutter build apk --release --split-per-abi --target-platform android-arm64

# add 32-bit phones too, if you want to support older devices
fvm flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

`android-arm64` → `arm64-v8a`, `android-arm` → `armeabi-v7a`,
`android-x64` → `x86_64` (emulators only). The finished files land in:

```
build/app/outputs/flutter-apk/app-<architecture>-release.apk
```

Release builds are signed with the debug key (see
[android/app/build.gradle.kts](android/app/build.gradle.kts)), so they're fine
for personal use but not for the Play Store.

To install on a connected device and launch it, from the project root:

```powershell
$adb = "$env:ANDROID_HOME\platform-tools\adb.exe"
& $adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
& $adb shell am start -n com.wisp.lightingcamera/.MainActivity
```

(Run these from `F:\Code\lightingcamera`, not a subfolder — the APK path is
relative to the project root.)

For the Play Store, build an app bundle instead — Google delivers the right
architecture to each device automatically:

```bash
fvm flutter build appbundle --release
```

## Tests

```bash
fvm flutter test
```
