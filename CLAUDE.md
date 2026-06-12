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
│   └── image_converter.dart        # YUV→RGB via native FFI, rotation, JPEG encode
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

```
CameraImage (YUV420)
  → native C FFI (YuvConverterFFI) with inline rotation
  → img.Image (RGB)
  → lazy JPEG encode via compute() isolate
```

- Camera streams frames at device FPS into an LRU cache (max 100 frames).
- Gallery lazy-converts cached frames in batches of 3 as the user scrolls.
- Saving encodes to JPEG at 95% quality and writes via the `gal` package.

## Key Patterns

- **Camera lifecycle:** `CameraPageState` mixes in `RouteAware` and `WidgetsBindingObserver` — recording pauses on route push / app background and resumes on return.
- **Volume shutter:** `volume_controller` intercepts hardware volume buttons as a shutter trigger; system volume UI is hidden while the camera page is visible.
- **FFI memory:** `Arena` from `package:ffi` handles native allocation — freed automatically in a `finally` block.
- **Device orientation:** `native_device_orientation` provides real-time orientation; rotation angle is computed per-frame accounting for front vs. back camera.

## Native Code

- Source: `native/yuv_converter.c` (YUV420 planar → RGB with 0°/90°/180°/270° rotation, integer arithmetic).
- CMake: `android/app/src/main/cpp/CMakeLists.txt` — compiles as shared lib with `-O3 -ffast-math` and NEON on ARM.
- NDK ABI filters: `arm64-v8a`, `armeabi-v7a`, `x86_64`.

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