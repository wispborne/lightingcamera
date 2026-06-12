# Speed Up Gallery Loading

## Problem

Opening the gallery after a capture is sluggish: scrolling stutters and every photo shows a spinner before it appears. The cause is structural — for each grid tile, the **UI thread** performs a full-resolution YUV→RGB conversion through native FFI (with ~4–5 full-frame buffer copies along the way), then decodes and uploads a full-camera-resolution GPU texture, all to fill a ~130px tile. Conversions run one at a time in batches of 3, triggered lazily from the grid's `itemBuilder`, so scrolling always outruns conversion. The lightning-detection scan packs NV21 buffers on the same UI thread at the same time, compounding the jank. Saving JPEG-encodes on the UI thread too. Memory is also wasteful: every viewed frame keeps a full-resolution RGB image *and* a full-resolution GPU texture (~16MB combined per frame, up to ~1.6GB across a full 100-frame buffer).

## Proposed Solution

Overhaul the pipeline so the UI thread never does per-frame pixel work, and the grid never handles more pixels than it shows:

- **Thumbnail-first grid.** The native converter gains an integer `scale` parameter (sample every Nth pixel during conversion), so grid thumbnails are converted at roughly tile resolution — 9–16× less work and a tiny texture per tile.
- **Background conversion pool.** Two long-lived worker isolates own all YUV→RGB conversion, JPEG encoding, and NV21 packing, fed by a two-level priority queue (fullscreen/save first, thumbnails behind). The UI thread only receives finished bytes and creates textures.
- **Eager thumbnails.** All cached frames (≤100) are queued for thumbnail conversion the moment the gallery opens, so scrolling never catches up to an unconverted tile — no more per-tile spinners.
- **Progressive fullscreen.** Opening a photo shows the thumbnail instantly (upscaled), then sharpens to full resolution when the background conversion lands; adjacent pages prefetch, distant full-res pages are dropped to bound memory.
- **Background saves.** "Save all" / "Save lightning" convert at full resolution and JPEG-encode (with EXIF) inside the workers, keeping the gallery responsive during multi-image saves.
- **Lightning scan off the UI thread.** The per-frame NV21 packing loop moves into the same worker pool at low priority; ML Kit labeling itself already runs natively.

Two latent correctness bugs get fixed in passing because the new native signature requires it: the converter currently ignores the Y plane's row stride (garbled output on devices with padded rows), and a `-90`° rotation from portrait-down capture is silently treated as 0°.

## Scope

- `native/yuv_converter.c`: scaled conversion with Y-row-stride support; `lib/native/yuv_converter_ffi.dart` binding update.
- New `lib/camera/yuv_conversion_pool.dart`: worker-isolate pool with priority queue, cancellation, and task types for RGBA conversion, JPEG encoding, and NV21 packing.
- `lib/camera/image_converter.dart`: `ProcessedImage` becomes a leaner `ProcessedFrame` (RGBA bytes → cached `ui.Image`, releasable CPU copy); rotation table exposed and normalized; thumbnail scale rule.
- `lib/camera/gallery_page.dart`: eager thumbnail generation, removal of the lazy batch machinery, progressive fullscreen viewer, pool-based saves.
- `lib/utils/photo_exif.dart`: isolate-sendable `JpegEncodeInfo` + encoder entry point (existing API kept as an adapter).
- `lib/camera/lightning_detection_service.dart`: NV21 packing via the pool.
- CLAUDE.md image-pipeline section update (currently describes a `compute()` step that doesn't exist).
- Host tests for the scale rule, rotation normalization, EXIF parity, and pool queue behavior.

## Non-Goals

- Changing the capture path, frame cache size, or camera page behavior — the raw YUV buffer and its FIFO semantics stay as they are.
- SIMD/NEON hand-optimization of the C converter — scaling + parallelism + off-thread execution deliver the win; revisit only if still needed.
- Disk-backed thumbnails or persistence — the gallery remains an in-memory review of the frozen buffer.
- Changing detection behavior, thresholds, or the ML Kit model.

## Risks / Open Questions

- **Behavior-visible bug fixes.** Y-row-stride handling and `-90`° normalization change rendered output on affected devices/orientations — *correctly*, but it must be verified on-device (portrait-down capture especially).
- **Save path always reconverts.** Thumbnails must never be saved (low-res), so saves convert full-res in workers. Conversion is cheap (~tens of ms/frame), but EXIF output must stay byte-equivalent — guarded by keeping the existing encoder test green through an adapter.
- **Isolate lifecycle races.** Results arriving after a deletion or gallery exit must be discarded; the existing generation-counter pattern plus queue cancellation covers this, and in-flight worker tasks are simply allowed to finish and be dropped.
- **Worker memory spikes.** Plane bytes are copied at send time, so at most two frames (~12MB) are duplicated in flight; queued requests hold references only.
