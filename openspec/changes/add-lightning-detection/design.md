# Design — Lightning Detection in Gallery

## Classifier choice

**Google ML Kit image labeling, base model** (`google_mlkit_image_labeling` pub package):

- Fully on-device, no API key, no network, no model file to ship — the base
  model is bundled/downloaded by Google Play services.
- Its built-in label map includes **"Lightning"**, so no training is needed.
- A custom TFLite model remains a drop-in upgrade later: only
  `LightningDetectionService` would change.

A frame is *flagged* when the labeler returns a `Lightning` label with
confidence ≥ `kLightningConfidenceThreshold` (single named constant, start at
`0.55`; the labeler's own option threshold is set lower, `0.40`, so near-miss
confidences are visible in logs for tuning).

## New: `lib/camera/lightning_detection_service.dart`

Top-level singleton `lightningDetectionService` (same pattern as
`imageCacheManager`):

- State (signals, read in UI via `SignalBuilder` — `Watch` is deprecated here):
  - `mapSignal<int, double> confidences` — sequenceNumber → confidence, only
    for flagged frames. Keyed by `ImageWithMetadata.sequenceNumber` so results
    survive deletions/reindexing in the grid.
  - `signal<int> scannedCount`, `signal<int> totalCount`,
    `late final isScanning = computed(() => scannedCount() < totalCount())`.
  - `bool isFlagged(int sequenceNumber)` convenience.
- `Future<void> scan(List<ImageWithMetadata> frames)` — sequential loop:
  convert frame → `InputImage` → `labeler.processImage` → record result, bump
  `scannedCount`. A generation counter makes `reset()` cancel a running scan
  (same trick as the gallery's `_generation`). Errors per frame are logged
  with `Fimber.e` and counted as scanned (never wedge the scan).
- `Future<void> whenScanComplete()` — completes immediately if idle, else when
  the current scan finishes. Used by the volume save-and-exit flow.
- `reset()` — bump generation, clear signals, close/recreate nothing (the
  `ImageLabeler` instance is created lazily once and closed in `reset()` to
  free native resources between gallery sessions).

### Feeding YUV frames to ML Kit

ML Kit on Android accepts raw **NV21** via `InputImage.fromBytes`. Cached
frames are YUV420 (3 planes). New pure-Dart helper in the service file:

- Copy the Y plane respecting `bytesPerRow` (row stride), then interleave
  V/U into the NV21 chroma block, handling both `uvPixelStride == 1`
  (planar) and `== 2` (semi-planar, the common Android case).
- `InputImageMetadata`: `format: nv21`, size from the frame, rotation mapped
  from the frame's `DeviceOrientation` + lens direction using the same
  rotation rules as `ImageConverter` (labeling is fairly rotation-tolerant,
  but correct rotation costs nothing here — it's metadata, not a pixel op).

No JPEG/RGB round-trip: detection does not touch the display-conversion
pipeline, so gallery thumbnails load exactly as fast as today.

## New: `lib/utils/volume_key_dispatcher.dart`

Today `MainActivity.onKeyDown` forwards every volume press over the
`com.wisp.lightingcamera/volume_keys` channel, and **camera_page.dart owns the
channel handler directly**. A second page calling `setMethodCallHandler` on the
same channel would silently steal it and break the shutter on return.

Replace direct ownership with a tiny singleton `volumeKeyDispatcher`:

- Owns the `MethodChannel` and sets its handler once (lazily on first
  subscribe).
- Keeps a **stack** of `void Function()` listeners; only the **top** listener
  receives a press. `subscribe(listener)` pushes, `unsubscribe(listener)`
  removes (any position, so out-of-order disposal is safe).
- Camera page: replace `_volumeKeyChannel.setMethodCallHandler(...)` with
  `subscribe` in `initState` / `unsubscribe` in `dispose`. Its existing
  `_volumeButtonsEnabled` / `_isPageVisible` / debounce logic stays inside its
  listener untouched (belt-and-suspenders with the stack ordering — R5).
- Gallery page: `subscribe` in `initState`, `unsubscribe` in `dispose`. While
  the gallery covers the camera it is the top listener, so the camera never
  sees gallery presses.

Native side (`MainActivity.kt`) is untouched — it already swallows the keys
(`return true`), so system volume never changes.

## Gallery page (`lib/camera/gallery_page.dart`)

### Scan lifecycle
- `initState`: after the existing post-frame callback, call
  `lightningDetectionService.scan(images)`.
- `_returnToCamera()` and `dispose`: `lightningDetectionService.reset()`.
- Deletion flows need no detection changes — results are keyed by sequence
  number, and `images` still holds the surviving `ImageWithMetadata` objects.

### Highlighting (R2)
- Tile (inside the existing `Stack`): when
  `isFlagged(images[index].sequenceNumber)`, wrap with a 2dp amber border
  (`colorScheme.tertiary` reads poorly on the forced-black grid; the page
  already uses literal colors — use `Colors.amber` to match the bolt icon)
  and add a small `Icons.bolt` badge **top-left** (top-right is taken by the
  selection circle). Badge read via `SignalBuilder` over `confidences` so it
  appears live mid-scan.
- Progress: `AppBar.bottom` → 2dp `LinearProgressIndicator` with
  `value: scanned/total`, visible only while `isScanning` (via
  `SignalBuilder`); disappears on completion. No layout shift for tiles.

### Save-lightning action (R3)
- Extract the body of `_saveAll()` into
  `Future<(int saved, int failed)> _saveImages(List<ImageWithMetadata> toSave)`
  (permission check, convert-or-reuse, JPEG 95, `Gal.putImageBytes`,
  snackbar stays in the callers). `_saveAll` calls it with all images.
- New app-bar `IconButton` left of "Save all": `Badge.count` (Material 3)
  wrapping `Icons.bolt`, count = flagged count, tooltip
  `'Save lightning (N)'`, disabled when count is 0 or a save is running.
  On tap: `_saveImages(images.where(flagged))`.
- Reuse `_isSavingAll`-style busy flag (one shared `_isSaving` covering both
  buttons keeps double-trigger impossible).

### Volume save-and-exit (R4)
- Gallery's dispatcher listener:
  - If the confirm dialog is **not** open → open it (`_volumeDialogOpen =
    true`).
  - If it **is** open → confirm (same code path as the dialog's confirm
    button).
- Dialog (pattern of the existing exit dialog): title "Save lightning &
  exit?", content via `SignalBuilder`:
  - scan running → "Scanning N/M…" + current flagged count, note that saving
    waits for the scan;
  - scan done, count > 0 → "Save N lightning image(s) to your device, then
    return to camera. Press a volume button again to confirm.";
  - count == 0 → "No lightning detected. Return to camera without saving?".
- Confirm: pop dialog → `await lightningDetectionService.whenScanComplete()`
  (with a blocking progress dialog if still scanning) → `_saveImages(flagged)`
  (skipped when zero) → `_returnToCamera()` (existing path: clears cache,
  pops route — and `reset()` the detection service).
- Cancel / tap-outside / back: `_volumeDialogOpen = false`; flow re-arms.

## Dependencies / build

- `pubspec.yaml`: add `google_mlkit_image_labeling` (latest stable).
- `android/app/build.gradle.kts`: verify `minSdk ≥ 21` (ML Kit floor) —
  expected already true; no other Gradle change needed for the base model.

## Failure modes

| Condition | Behavior |
|---|---|
| ML Kit unavailable (e.g. Play services missing) | First `processImage` throws → logged, scan marks all frames scanned, zero flagged; gallery behaves as today |
| Per-frame labeling error | Logged, frame counted as scanned & unflagged, scan continues |
| Scan still running at volume-confirm | Dialog shows progress; save starts when scan completes |
| User deletes flagged frames mid-scan | Results keyed by sequence number — no misattribution; counts recompute from surviving images |
| Zero lightning found | Save-lightning button disabled; volume flow offers plain exit |
