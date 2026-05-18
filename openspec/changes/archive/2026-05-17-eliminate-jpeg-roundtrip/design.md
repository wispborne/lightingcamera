# Design: Eliminate JPEG Roundtrip

## Technical Approach

### Core Change: `ProcessedImage` produces `ui.Image` directly

The `img.Image` from FFI contains raw pixel data in its `buffer`. We convert this to RGBA format (adding alpha channel if needed) and pass it to `dart:ui decodeImageFromPixels()`, which returns a `ui.Image` — the native format Flutter's rendering engine uses.

```dart
import 'dart:ui' as ui;

class ProcessedImage {
  final img.Image image;
  ui.Image? _uiImage;

  Future<ui.Image> get displayImage async {
    if (_uiImage != null) return _uiImage!;
    _uiImage = await _createUiImage();
    return _uiImage!;
  }

  Future<ui.Image> _createUiImage() {
    final completer = Completer<ui.Image>();
    final bytes = image.toUint8List(); // RGBA pixel data
    ui.decodeImageFromPixels(
      bytes,
      image.width,
      image.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
```

### Pixel Format Consideration

The native FFI currently outputs RGB (3 bytes per pixel, `ChannelOrder.rgb`). `decodeImageFromPixels` requires RGBA (4 bytes per pixel). Two options:

1. **Convert in Dart** — iterate the buffer and insert alpha bytes. Simple but allocates a new buffer.
2. **Modify native C to output RGBA** — add a 4th byte (0xFF) per pixel in the C conversion. Zero extra allocation, marginally more work in native code.

**Decision:** Modify native C to output RGBA. The native code already writes 3 bytes per pixel in a loop — adding a 4th constant byte is trivial and avoids a second buffer allocation in Dart.

### Widget Changes

Gallery tiles and fullscreen viewer replace:
```dart
FutureBuilder<Uint8List>(
  future: displayImage.displayableBytes,
  builder: (ctx, snap) => snap.hasData
    ? Image.memory(snap.requireData)
    : CircularProgressIndicator(),
)
```

With:
```dart
FutureBuilder<ui.Image>(
  future: displayImage.displayImage,
  builder: (ctx, snap) => snap.hasData
    ? RawImage(image: snap.requireData, fit: BoxFit.cover)
    : CircularProgressIndicator(),
)
```

### Memory & Lifecycle

`ui.Image` is a GPU-backed resource that must be disposed. The `ProcessedImage` class gains a `dispose()` method, and the gallery page calls it when images leave the viewport or on page dispose.

### Save Path (unchanged conceptually)

The "save to gallery" action still calls `img.encodeJpg(image, quality: 95)` — that path is only hit on explicit user action, not during browsing.

## Files Changed

| File | Change |
|------|--------|
| `native/yuv_converter.c` | Output RGBA (4 bytes/pixel) instead of RGB (3 bytes/pixel) |
| `android/app/src/main/cpp/CMakeLists.txt` | No change needed |
| `lib/native/yuv_converter_ffi.dart` | Update buffer size calculation (w×h×4 instead of w×h×3) |
| `lib/camera/image_converter.dart` | Use `ChannelOrder.rgba`, add `ui.Image` creation, dispose support |
| `lib/camera/gallery_page.dart` | Replace `FutureBuilder<Uint8List>` + `Image.memory` with `FutureBuilder<ui.Image>` + `RawImage`; add dispose calls |

## Key Decisions

- RGBA output from native code (avoids second buffer allocation in Dart)
- `ui.Image` cached per `ProcessedImage` instance (created once, reused)
- `dispose()` required — gallery page manages lifecycle
