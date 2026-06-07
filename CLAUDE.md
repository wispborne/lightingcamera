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

## AI Assistant Instructions

- Avoid using jargon in your responses.