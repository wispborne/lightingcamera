# Design — Speed Up Gallery Loading

## Architecture

```
Grid tile (~360px thumb)            Fullscreen / Save (full res)     Lightning scan (NV21)
        │                                    │                              │
        ▼                                    ▼                              ▼
eager thumbnails (all ≤100,          on-demand, HIGH priority        packing, LOW priority
 NORMAL priority, grid order)                │                              │
        └──────────────┬─────────────────────┴──────────────────────────────┘
                       ▼
        YuvConversionPool — 2 long-lived worker isolates, two-level priority queue
                       │   FFI: convert_yuv_to_rgb_scaled(..., y_row_stride, rotation, scale)
                       ▼
        RGBA bytes / JPEG bytes / NV21 bytes → main isolate
                       ▼
        decodeImageFromPixels → ui.Image (display)   |   Gal.putImageBytes (save)   |   ML Kit (scan)
```

The principle: the main isolate never touches pixels. It enqueues work, receives
bytes, and turns RGBA into textures (`decodeImageFromPixels` hands off to the
engine). Everything pixel-shaped — color conversion, scaling, rotation, JPEG
encoding, NV21 packing — happens in the pool.

## Native converter (`native/yuv_converter.c`)

Replace `convert_yuv_to_rgb` with:

```c
void convert_yuv_to_rgb_scaled(
        const uint8_t *y_plane, const uint8_t *u_plane, const uint8_t *v_plane,
        uint8_t *rgb_output,
        int width, int height,
        int y_row_stride,        // NEW — current code assumes width (bug on padded-row devices)
        int uv_row_stride, int uv_pixel_stride,
        int rotation,            // 0 / 90 / 180 / 270, normalized by the Dart side
        int scale);              // >= 1; output is (width/scale) x (height/scale) pre-rotation
```

- Loop over **output** pixels: `src_x = ox * scale`, `src_y = oy * scale`;
  `y_index = src_y * y_row_stride + src_x`; UV index from `src_x/2`, `src_y/2`
  as today. Same fixed-point YUV→RGB math, same inline-rotation `switch`, with
  `dest_width` computed from the *scaled* dimensions.
- `scale=1` reproduces today's full-resolution path (modulo the stride fix).
- Two latent bugs die here: Y row stride is honored, and rotation is fully
  enumerated because the Dart side normalizes `-90` → `270` (the current C
  `switch` silently treats `-90` as 0°).
- Single caller, private lib: the old symbol is deleted, no compatibility
  wrapper. No CMake change (same source file, flags unchanged).

## FFI binding (`lib/native/yuv_converter_ffi.dart`)

- Typedefs/lookup updated for the two new `Int32` params; Dart API moves to
  named parameters with `scale` defaulting to 1; output buffer allocated as
  `(width ~/ scale) * (height ~/ scale) * 4`.
- Already isolate-safe: `_loadLibrary()` is a lazy per-isolate static, so each
  worker opens `libyuv_converter.so` once on first use. No change needed.

## New: `lib/camera/yuv_conversion_pool.dart`

Top-level singleton `yuvConversionPool` (same pattern as `imageCacheManager`).

```dart
enum ConversionPriority { high, normal, low }   // fullscreen/save · thumbnails · NV21

class YuvConversionRequest {     // built from ImageWithMetadata via a helper
  // plane Uint8Lists (references!), dims, strides,
  // rotation (normalized), scale, and a task type:
  //   rgba  → returns RGBA bytes + post-rotation dims
  //   jpeg  → carries JpegEncodeInfo; worker encodes, returns JPEG bytes
  //   nv21  → returns packed NV21 bytes (ignores rotation/scale)
}

class YuvConversionPool {
  Future<YuvConversionResult> convert(YuvConversionRequest r,
      {ConversionPriority priority = ConversionPriority.normal});
  void cancelPending();          // drops queued (not in-flight) tasks
}
```

Key decisions:

- **2 long-lived workers, not `Isolate.run` per task.** ~100 eager thumbnail
  tasks would each pay isolate spawn + per-isolate `DynamicLibrary.open`; the
  pool amortizes both and is the single home for prioritization and
  cancellation. Two workers let a save batch parallelize while one slot stays
  free for a fullscreen request. (Fixed 2 — Android-only, no need to scale by
  core count.)
- **Queue holds references; copies happen at send.** A queued request holds the
  cached frame's plane `Uint8List`s by reference — zero added memory for a full
  100-frame backlog. Plane bytes are copied by `SendPort.send` only when a
  worker picks the task up, so at most `workers` frames (~12MB) are duplicated
  in flight. **No `TransferableTypedData` on cached planes** — those buffers
  belong to the live frame cache; transferring would detach them.
- **Three-level queue** is just three `Queue`s popped in order — no heap.
- **Worker protocol**: handshake SendPort, then `(id, taskMap)` request /
  `(id, bytes, w, h)` or `(id, errorString)` reply; main side correlates via
  `Map<int, Completer>`. Errors are stringified in the worker and logged with
  `Fimber.e` on the main isolate (Fimber trees are per-isolate and unconfigured
  in workers).
- `package:image` (JPEG encode) is pure Dart — isolate-safe. Anything
  platform-channel-backed (ML Kit, Gal, permissions) stays on the main isolate.
- Lifecycle: workers lazy-start on first `convert()`; they idle for the app
  session (two parked isolates cost ~nothing; respawning per gallery visit
  would re-add latency). Gallery `dispose()` calls `cancelPending()`.

## `ProcessedImage` → `ProcessedFrame` (`lib/camera/image_converter.dart`)

```dart
class ProcessedFrame {
  ProcessedFrame(Uint8List rgba, this.width, this.height);
  Future<ui.Image> get uiImage;   // decodeImageFromPixels once, cached (as today)
  void releaseBytes();            // drop the CPU-side RGBA after the texture exists
  img.Image toImgImage();         // save path only (worker-side)
  void dispose();                 // disposes the ui.Image
}
```

- The synchronous `ImageConverter.processImage`, the old `ProcessedImage`, and
  the dead `_convertYuvToRgbDart` are deleted.
- `_getRotationAngle` becomes public `static int rotationFor(orientation, lens)`
  returning normalized `0/90/180/270` (`-90` → `270`). The lightning service's
  duplicate `_rotationFor` table collapses onto it.
- `static int thumbScaleFor(int w, int h) => max(1, min(w, h) ~/ 360);` —
  thumbnails target ≥360px on the short side (sharp up to a 2-column grid on a
  1080p screen). At 1920×1080 → scale 3 → 640×360 ≈ 0.9MB per thumb; 100 thumbs
  ≈ 90MB of textures after `releaseBytes()`, versus up to ~1.6GB today.

## Gallery page (`lib/camera/gallery_page.dart`)

### Grid
- `Map<int, ProcessedImage> _displayImages` → `Map<int, ProcessedFrame> _thumbs`.
- `initState`'s post-frame callback enqueues **every** frame for thumbnail
  conversion in index order at `normal` priority (visible tiles resolve first
  naturally). Each completion: guard `mounted && _generation == gen` → await
  `uiImage` → `releaseBytes()` → `setState`. (~100 setStates over a few seconds
  is fine; coalescing behind a ~32ms flush timer is a noted fallback if rebuild
  churn shows.)
- The lazy machinery dies: `_convertImageBatch`, `_convertSingleImage`,
  `_convertCameraImageToUIImage`, the `itemBuilder` trigger, the
  `_currentlyConverting` bookkeeping, and the lightning strip's per-tile
  conversion trigger (the strip reads `_thumbs` directly).
- Tile placeholder: the existing dim icon until the thumb lands — no spinner.
- Deletion (`keep/delete selected`): existing `_generation` bump discards
  in-flight results; additionally `cancelPending()` then re-enqueue thumbs
  missing under the remapped indices.
- `dispose()`: unchanged disposal of frames, plus `cancelPending()`.

### Fullscreen (`FullscreenImagePage`)
- Takes `Map<int, ProcessedFrame> thumbs` (renamed); `_localConverted` now
  holds **full-resolution** `ProcessedFrame`s requested from the pool at
  `high` priority.
- Page builder: full-res ready → `RawImage` in the `InteractiveViewer` as
  today; otherwise the **thumbnail** upscaled (`BoxFit.contain`) — instant page
  flips that sharpen in place. Spinner only in the no-thumbnail-yet corner case.
- Keep ±1 prefetch on `onPageChanged`; additionally dispose `_localConverted`
  entries outside `index ± 2` (each full-res texture ≈ 8MB).

### Saves
- `_saveImages` and fullscreen `_saveImage`: per frame, one pool request at
  `scale: 1` with `jpeg: info` (high priority, 2–3 in flight via a windowed
  `Future.wait`) → `Gal.putImageBytes`. The convert-or-reuse block disappears —
  thumbnails must never be saved, and a full-res worker conversion is ~tens of
  ms. Permission flow, busy flag, counts, and snackbars unchanged.

## EXIF encoding (`lib/utils/photo_exif.dart`)

- New isolate-sendable `JpegEncodeInfo` (primitive fields only: timestamp, lat/
  long/alt/heading, GPS timestamp, make/model, quality 95) plus
  `Uint8List encodeJpgWithInfo(img.Image, JpegEncodeInfo)`.
- Existing `encodeJpgWithMetadata(...)` (takes `geolocator.Position`) becomes a
  thin adapter building a `JpegEncodeInfo` and delegating — `test/photo_exif_test.dart`
  keeps passing and pins EXIF parity.
- Callers resolve position/device info once per save batch (as today) and ship
  one `JpegEncodeInfo` template into the workers.

## Lightning detection (`lib/camera/lightning_detection_service.dart`)

- ML Kit's `labeler.processImage` is a platform channel — already executes
  natively off the Dart thread. The real main-isolate cost is `_yuv420ToNv21`:
  a ~0.5M-iteration Dart loop per frame × 100 frames, running exactly while
  thumbnails generate.
- `scan()` requests NV21 packing from the pool at `low` priority (thumbnails
  and fullscreen always win), then builds `InputImage.fromBytes` and labels on
  the main isolate as today. Sequential flow, generation guard, progress
  signals, and result keying are untouched.
- `_rotationFor`'s angle table is replaced by `ImageConverter.rotationFor` +
  the existing angle→`InputImageRotation` mapping.

## Failure modes

| Condition | Behavior |
|---|---|
| Worker conversion throws | Error string back to main isolate, `Fimber.e`; tile keeps placeholder / save counts a failure; queue continues |
| Worker isolate dies | Pending completers for that worker fail; pool respawns the worker lazily on next request |
| Gallery exits mid-generation | `cancelPending()` rejects queued tasks; in-flight results land but are dropped by the `_generation` guard |
| Frames deleted mid-generation | Same as above, then missing thumbs re-enqueued under remapped indices |
| Save while thumbnails still generating | Save requests are `high` priority and jump the thumbnail backlog |
| Padded Y rows / portrait-down capture | Rendered correctly (stride honored; `-90` normalized to `270`) — visibly *different* from today on affected devices, by design |

## Docs

CLAUDE.md's Image Pipeline section currently claims "lazy JPEG encode via
compute() isolate" — no `compute()` exists. Rewrite that section to describe
the pool-based pipeline as part of this change.
