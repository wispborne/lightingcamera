# Eliminate JPEG Roundtrip in Gallery Display

## Problem

Gallery images show a spinner for a noticeable duration before displaying. The root cause is a wasteful encode/decode cycle: after native FFI converts YUV→RGB, the pipeline JPEG-encodes the pixels (via `compute()`) just so Flutter can JPEG-decode them back into a raster for display. This double-conversion dominates the per-image latency in the gallery grid.

Current path:
```
YUV → RGB (native FFI) → img.Image → JPEG encode (isolate) → Image.memory → Flutter JPEG decode → display
                                       ~50-100ms per frame       ~20-40ms per frame
```

## Proposed Solution

Replace the JPEG encode→decode display path with direct pixel rendering using `dart:ui decodeImageFromPixels()`. The RGB byte buffer from the FFI conversion is already in memory — feed it directly to Flutter's raster pipeline to produce a `ui.Image`, then display via `RawImage` widget.

New path:
```
YUV → RGB (native FFI) → RGBA bytes → decodeImageFromPixels → ui.Image → RawImage widget
```

JPEG encoding is retained only for the "save to gallery" action, where it's actually needed.

## Scope

- Modify `ProcessedImage` to produce a `ui.Image` from raw pixel data instead of JPEG bytes
- Update gallery grid tiles and fullscreen viewer to use `RawImage` instead of `Image.memory`
- Keep JPEG encode path available for the save-to-device feature

## Non-Goals

- Moving YUV→RGB to a background isolate (separate improvement)
- Thumbnail generation / downscaling for grid view (separate improvement)
- Changing the camera capture pipeline
