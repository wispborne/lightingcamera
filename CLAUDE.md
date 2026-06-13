# Lightning Camera

Flutter camera app (Android) that continuously streams camera frames into an in-memory cache, lets the user review them in a gallery, and save to device.


## Architecture

```
lib/
├── main.dart                       # entry point, GoRouter config, theme
├── camera/
│   ├── camera_page.dart            # live camera feed, exposure slider, volume shutter
│   ├── gallery_page.dart           # image grid, fullscreen viewer, save-to-gallery
│   ├── image_cache_manager.dart    # LRU frame cache (signals)
│   ├── image_converter.dart        # ProcessedFrame (RGBA→ui.Image), rotation + thumb-scale helpers
│   └── yuv_conversion_pool.dart    # background worker-isolate pool: YUV→RGBA, JPEG, NV21
├── native/
│   └── yuv_converter_ffi.dart      # dart:ffi bindings to libyuv_converter.so
└── utils/
    └── logging.dart                # Fimber logging wrapper (use instead of print)
```

- **State management:** `signals` package — `ImageCacheManager` uses `listSignal` / `computed` as a top-level singleton (`imageCacheManager`).
- **Routing:** GoRouter with named routes defined in the `Pages` class (`/` → camera, `/gallery` → gallery).
- **Logging:** `Fimber` static methods (`Fimber.d()`, `Fimber.e()`, etc.) wrapping the `logger` package. Always use `Fimber` instead of `print()`.
- **Platform:** Android only. Package: `com.wisp.lightingcamera`.

## Image Pipeline

All per-frame pixel work runs off the UI thread, in the `yuvConversionPool`
(two long-lived worker isolates with a high/normal/low priority queue). The main
isolate only builds requests, receives bytes, and uploads textures.

```
CameraImage (YUV420)  ── plane bytes + strides ──▶  YuvConversionRequest
                                                          │ (pool, background isolate)
                                                          ▼
                              native C FFI (convert_yuv_to_rgb_scaled,
                              inline rotation + integer downscale)
                                                          ▼
   ┌──────────────────────────┬───────────────────────────┬─────────────────────┐
   ▼ thumbnail (scaled RGBA)  ▼ full-res RGBA              ▼ JPEG (EXIF)          ▼ NV21
 grid: ProcessedFrame       fullscreen: ProcessedFrame   save: Gal.putImageBytes  lightning scan
 → ui.decodeImageFromPixels → ui.decodeImageFromPixels
```

- Camera streams frames at device FPS into a FIFO cache (max 100 frames).
- Gallery eagerly converts **all** frames to reduced-resolution thumbnails on
  open, so scrolling never waits on a conversion. `ImageConverter.thumbScaleFor`
  picks the downscale factor (~360px short side).
- Fullscreen shows the thumbnail upscaled instantly, then swaps to a full-res
  conversion (kept only within ±2 pages); the grid keeps thumbnails only.
- Saving converts at full resolution and JPEG-encodes (95% quality, EXIF via
  `encodeJpgWithInfo`) **inside the workers**, then writes via the `gal` package.
- The native converter honors the Y-plane row stride and a normalized
  0/90/180/270 rotation (`ImageConverter.rotationFor`).

## Key Patterns

- **Camera lifecycle:** `CameraPageState` mixes in `RouteAware` and `WidgetsBindingObserver` — recording pauses on route push / app background and resumes on return.
- **Volume shutter:** `volume_controller` intercepts hardware volume buttons as a shutter trigger; system volume UI is hidden while the camera page is visible.
- **FFI memory:** `Arena` from `package:ffi` handles native allocation — freed automatically in a `finally` block.
- **Device orientation:** `native_device_orientation` provides real-time orientation; rotation angle is computed per-frame accounting for front vs. back camera.

## Native Code

- Source: `native/yuv_converter.c` (YUV420 planar → RGB with 0°/90°/180°/270° rotation, integer arithmetic).
- CMake: `android/app/src/main/cpp/CMakeLists.txt` — compiles as shared lib with `-O3 -ffast-math` and NEON on ARM.
- NDK ABI filters: `arm64-v8a`, `armeabi-v7a`, `x86_64`.

## Relay (`relay/`)

A small **Node** service (ESM, deps: `ws` + `yaml`) that the lightning features talk to.
It holds one upstream websocket to the [Blitzortung](https://www.blitzortung.org/)
community lightning network, decodes the feed, and fans strikes out to clients — each app
client filtered to a bounding box around the user. A relay is required because
Blitzortung's data policy forbids connecting phones directly, and the data is
**non-commercial only**. The full reference is `relay/README.md`; the essentials:

```
relay/
├── index.js              # entry point: wires upstream -> servers, holds connection open
├── spike.js              # standalone go/no-go test (prints decoded strikes)
├── config.default.yaml   # shipped, commented defaults (do not edit)
├── config.yaml           # gitignored local overlay (auth keys, host/port, tls, web)
├── lightning-relay.service  # systemd unit for the VPS
├── src/
│   ├── decode.js         # Blitzortung LZW decode + strike normalization
│   ├── config.js         # config loader (defaults <- config.yaml) + logger
│   ├── geo.js            # center+radius -> bounding box, in-box test
│   ├── upstream.js       # Blitzortung connection, reconnect/failover, heartbeat
│   ├── subscribers.js    # shared gauge: live count of app + web viewers
│   ├── history.js        # rolling last-5-min strike buffer, snapshotted to disk
│   ├── server.js         # app-facing websocket server + box fan-out
│   └── web.js            # browser-facing world map: static page + unfiltered /ws
└── web/                  # the world map page (vanilla JS + vendored Leaflet)
```

- **Data flow:** `upstream.js` decodes each Blitzortung strike → `index.js` drops stale
  ones, adds to `history`, then broadcasts to `server` (app clients) and `web` (map). The
  upstream stays connected for the relay's whole lifetime, so `history` keeps filling even
  with no clients — a freshly opened map is already populated.
- **Strike shape:** `{ "type": "strike", "lat": <deg>, "lon": <deg>, "time": <ms epoch> }`.
- **App protocol:** client connects, sends `{ "auth": "<key>" }` as the **first** message
  (relay acks or closes with `4001`), then `{ "lat", "lon", "radiusKm" }` to set/move its
  box. Relay streams matching strikes. Keepalive: ws-level ping + app-level
  `{ "type": "ping" }` every `server.heartbeatMs` (30s). Close codes 4000–4004 are
  documented in the README (auth timeout, unauthorized, session expired, IP banned, too
  many connections).
- **Auth:** private — keys live in `config.yaml` under `auth.keys` (name → key). No key
  rotation/DB; editing the file + restart is how you grant/revoke.
- **Web map (optional):** `web.enabled` serves an unfiltered world map on a second port
  (`/ws` needs no key) — keep it on `127.0.0.1` behind Caddy + tinyauth, never exposed.
- **App side:** the Flutter client lives in `lib/lightning/` (`lightning_service.dart`
  holds the relay URL and websocket logic; `alert_service`, `strike_overlay`, `mini_map`,
  `lightning_map_page` consume it).
- **Run:** `cd relay && npm install`, then `npm run spike` (sanity check, prints 5 strikes
  and exits) or `npm start` (serves `ws://0.0.0.0:8787`). Deploy via the systemd unit on
  the VPS; the app needs `wss://`, so terminate TLS at a reverse proxy.

## UI Guidelines

Follow minimal Material Design 3 best practices:

- **8dp grid:** All spacing, padding, and margin values must be multiples of 8. Use 4dp only for tight internal spacing (e.g. icon-to-label gap within a single component).
- **Touch targets:** Minimum 48×48dp for all interactive elements.
- **Typography:** Use Material `TextTheme` styles — never hard-code font sizes.
- **Color:** Pull colors from `Theme.of(context).colorScheme` — never hard-code color values.
- **Elevation & surfaces:** Prefer Material surface tints over drop shadows. Keep the layer count low — one overlay level at most.
- **Iconography:** Use `Icons.*` from Material. Keep icons simple and monochrome, matching `colorScheme.onSurface`.
- **Layout:** Favor `Padding`, `SizedBox`, and `Gap` for whitespace over `Container` with decoration. Avoid deeply nested widgets when a single `Column`/`Row` with spacing suffices.
- **Minimalism:** No decorative borders, dividers, or background fills unless they serve a clear functional purpose (grouping, separation of unrelated content). When in doubt, leave it out.
- **Safe areas:** Never position content under the status bar or navigation bar. Use `MediaQuery.of(context).padding` to get system insets and offset accordingly (top for status bar, bottom for nav bar). This applies to all `Positioned` widgets in full-screen `Stack` layouts, overlays, and `extendBodyBehindAppBar` screens.

## AI Assistant Instructions

- Avoid using jargon in your responses.
- Don't offer to build and run the app and don't do it yourself.
- - Use `fvm flutter` instead of the `flutter` command directly.

## Other

- 'Watch' is deprecated and shouldn't be used. Use SignalBuilder instead for superior reactivity and consistent naming.
- Use the new `spacing` parameter on `Row`/`Column` instead of `SizedBox` separators when spacing is even.
- Prefer Dart's dot shorthand — e.g. `.all(8.0)` over `EdgeInsets.all(8.0)`.