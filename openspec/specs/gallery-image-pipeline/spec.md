# Gallery Image Pipeline

Fast, jank-free gallery browsing of the frozen capture buffer: thumbnails convert in background isolates at reduced resolution and are all pre-generated on open; fullscreen viewing is progressive (instant soft image, then full resolution); saves convert and JPEG-encode off the UI thread; the lightning scan's buffer packing moves off the UI thread too.

## Requirements

### R1: No per-frame pixel work on the UI thread

All YUV→RGB conversion, JPEG encoding, and NV21 packing MUST run outside the main isolate. The main isolate only dispatches requests, receives finished bytes, and creates textures.

#### Acceptance
- While thumbnails generate, while fullscreen images sharpen, while a multi-image save runs, and while the lightning scan runs, the gallery remains scrollable and interactive with no visible stutter.
- Worker isolates are long-lived (started on first use, kept for the app session); per-task isolate spawning is not used.
- Higher-priority work (fullscreen viewing, saving) is served before pending thumbnail work.
- A failed conversion in a worker is logged on the main isolate and affects only that frame (placeholder tile / failed-save count), never the pipeline.

### R2: Instant thumbnail grid

Grid tiles MUST display reduced-resolution thumbnails generated eagerly for the whole buffer, so scrolling never waits on conversion.

#### Acceptance
- Thumbnail conversion for every cached frame is queued as soon as the gallery opens, in grid order, without any scroll interaction.
- Thumbnails are converted at a reduced scale targeting roughly tile resolution (≥360px on the short side), not full camera resolution.
- Tiles fill in progressively; once a thumbnail exists, scrolling anywhere in the grid never shows a loading spinner for it.
- The lightning section strip reuses the same thumbnails (no separate conversion path).
- Total thumbnail memory for a full 100-frame buffer stays in the low hundreds of MB at most (each thumbnail's CPU-side pixel buffer is released once its texture exists) — strictly below today's full-resolution behavior.
- Deleting frames cancels pending thumbnail work and re-queues only what the surviving indices still need; stale results from before the deletion are discarded.

### R3: Progressive fullscreen viewing

Opening a photo or swiping between photos MUST show an image immediately, sharpening to full resolution when ready.

#### Acceptance
- On open or page change, the (upscaled) grid thumbnail is shown immediately — never a blank page or bare spinner when a thumbnail exists.
- The full-resolution image replaces the thumbnail as soon as its background conversion completes; pinch-zoom operates on the full-resolution image.
- Adjacent pages (±1) prefetch at high priority; full-resolution images for pages outside the immediate neighborhood (beyond ±2) are released so fullscreen browsing memory stays bounded.

### R4: Full-resolution saves, encoded in the background

Saving (save all, save lightning, fullscreen single save) MUST always write full-resolution JPEGs with the same EXIF metadata as today, encoded off the UI thread.

#### Acceptance
- Saved files are full camera resolution regardless of what the grid displays — a thumbnail is never written to disk.
- EXIF output (timestamp, GPS fields when geotagging is on, make/model, quality 95) is identical to the current encoder's; the existing encoder test passes unchanged.
- The gallery stays responsive during a 100-image save; the existing busy flag/progress UX is preserved.
- Saved/failed counts and snackbars behave exactly as today.

### R5: Correct rendering on all devices and orientations

The native converter MUST honor the Y plane's row stride and all four capture rotations.

#### Acceptance
- Devices whose camera pads Y rows (row stride > width) render correctly (no skew/garble) in thumbnails, fullscreen, and saved files.
- Frames captured in portrait-down orientation render rotated correctly (the previous `-90` → "no rotation" fallthrough is fixed); all of 0°/90°/180°/270° are covered.
- Thumbnail and full-resolution renderings of the same frame agree in orientation and colors.

### R6: Lightning scan keeps up without touching the UI thread

The detection scan's per-frame NV21 packing MUST run in the background pool without changing detection results or UX.

#### Acceptance
- Scan results (per-frame confidences, hit set, progress indicator, threshold re-filtering) are unchanged in behavior and timing visibility.
- NV21 packing runs at a priority that never delays thumbnail generation or fullscreen viewing.
- Leaving the gallery mid-scan cancels cleanly exactly as today (generation guard); no stale results are recorded.
