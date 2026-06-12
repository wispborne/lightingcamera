# Design — Lightning Detection in Gallery

## Classifier choice

**Google ML Kit image labeling, base model** (`google_mlkit_image_labeling` pub package):

- Fully on-device, no API key, no network, no model file to ship — the base
  model is bundled/downloaded by Google Play services.
- Its built-in label map includes **"Lightning"**, so no training is needed.
- A custom TFLite model remains a drop-in upgrade later: only
  `LightningDetectionService` would change.

A frame is a *hit* when its recorded `Lightning` confidence ≥ the user's
threshold setting (`settingsManager.lightningThreshold`, default `0.55`, see
Settings below). The labeler's own option threshold is pinned **at or below the
slider minimum** (`0.10`) so every selectable threshold has data to filter —
the scan records each frame's confidence once and re-thresholding never needs a
rescan. Frames the labeler returns no `Lightning` label for are recorded as
confidence `0.0` (scanned, never a hit).

## New: `lib/camera/lightning_detection_service.dart`

Top-level singleton `lightningDetectionService` (same pattern as
`imageCacheManager`):

- State (signals, read in UI via `SignalBuilder` — `Watch` is deprecated here):
  - `mapSignal<int, double> confidences` — sequenceNumber → `Lightning`
    confidence for **every** scanned frame (including `0.0` non-detections),
    keyed by `ImageWithMetadata.sequenceNumber` so results survive
    deletions/reindexing in the grid. Storing all frames (not just hits) is
    what lets the threshold slider re-filter without a rescan.
  - `signal<int> scannedCount`, `signal<int> totalCount`,
    `late final isScanning = computed(() => scannedCount() < totalCount())`.
  - `bool isHit(int sequenceNumber)` → confidence ≥
    `settingsManager.lightningThreshold` (reads the threshold signal, so any
    `computed`/`SignalBuilder` built on it recomputes when the slider moves).
  - `List<int> hitsByConfidence(List<ImageWithMetadata> frames)` → the given
    frames whose confidence clears the threshold, sorted descending — the data
    source for the top section (R6). Implemented as / behind a `computed` so it
    tracks both `confidences` and the threshold signal.
- `Future<void> scan(List<ImageWithMetadata> frames)` — sequential loop:
  convert frame → `InputImage` → `labeler.processImage` → record the
  `Lightning` confidence (or `0.0`), bump `scannedCount`. A generation counter
  makes `reset()` cancel a running scan (same trick as the gallery's
  `_generation`). Errors per frame are logged with `Fimber.e` and recorded as
  `0.0` / scanned (never wedge the scan).
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

### Lightning section (R6)
- A `_LightningSection` band sits **between the app bar and the main grid**, in
  the `Column`/body above the existing grid (the grid stays in an `Expanded`
  below it). Keeping it outside `DragSelectGridView` avoids fighting that
  widget's own scrolling — it's a self-contained horizontal strip, not a
  second sliver.
- Built in a `SignalBuilder` over `hitsByConfidence(images)` (tracks both
  `confidences` and the threshold signal, so it fills in live and re-filters
  when the slider moves):
  - Zero hits → renders nothing (`SizedBox.shrink`), so an empty/no-lightning
    capture looks like today's gallery (R6).
  - Otherwise: a header row "Lightning (N)" (`text.titleSmall`) + a
    fixed-height (~96dp) horizontal `ListView` of square thumbnails, most
    confident first. Each reuses the same converted `ProcessedImage` from
    `_displayImages` when present, else shows the same spinner placeholder as
    the grid; tapping opens `_showFullscreenImage` at that image's grid index.
  - A small `Icons.bolt` + confidence caption (e.g. "82%") on each strip tile.
- The strip height is fixed and only present when there are hits, so it costs
  one overlay level and no layout thrash per the UI guidelines.

### Gallery sensitivity control (R7)
- An app-bar `IconButton` (`Icons.tune`, tooltip "Lightning sensitivity")
  toggles a local `bool _showSensitivity`. When on, a compact slider row drops
  in **below the app bar** (as `AppBar.bottom`, sharing that strip with the
  scan progress indicator — progress on top, slider beneath; together they are
  the one allowed overlay strip, no extra `Stack` layer).
- The row is a `SignalBuilder` over `lightningThresholdSignal`: a `Slider`
  (min/max = the threshold constants, same divisions as the settings slider)
  with a leading `Icons.bolt` and a trailing percentage. `onChanged` →
  `settingsManager.setLightningThreshold`, so dragging it persists immediately
  and — because the top section, badges, and save count are all `SignalBuilder`s
  on the same signal — re-filters them live with no rescan.
- Reachable regardless of hit count (it lives in the app bar, not the hit-gated
  top section), so the user can drag the threshold down to surface faint bolts
  the default missed.
- Same widget binds the same setter as the settings-page slider, so the two
  stay in sync for free (one shared signal); default hidden to keep the gallery
  clean until the user wants to tune.

### Highlighting (R2)
- Tile (inside the existing `Stack`): when
  `isHit(images[index].sequenceNumber)`, wrap with a 2dp amber border
  (`colorScheme.tertiary` reads poorly on the forced-black grid; the page
  already uses literal colors — use `Colors.amber` to match the bolt icon)
  and add a small `Icons.bolt` badge **top-left** (top-right is taken by the
  selection circle). Read via `SignalBuilder` over `confidences` + the
  threshold signal so it appears live mid-scan and updates when the slider
  moves.
- Progress: `AppBar.bottom` → 2dp `LinearProgressIndicator` with
  `value: scanned/total`, visible only while `isScanning` (via
  `SignalBuilder`); disappears on completion. No layout shift for tiles.

### Save-lightning action (R3)
- Extract the body of `_saveAll()` into
  `Future<(int saved, int failed)> _saveImages(List<ImageWithMetadata> toSave)`
  (permission check, convert-or-reuse, JPEG 95, `Gal.putImageBytes`,
  snackbar stays in the callers). `_saveAll` calls it with all images.
- New app-bar `IconButton` left of "Save all": `Badge.count` (Material 3)
  wrapping `Icons.bolt`, count = hit count (via `SignalBuilder` so it tracks
  the scan and the threshold), tooltip `'Save lightning (N)'`, disabled when
  count is 0 or a save is running. On tap: `_saveImages(hit images)`.
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
  - scan running → "Scanning N/M…" + current hit count, note that saving
    waits for the scan;
  - scan done, count > 0 → "Save N lightning image(s) to your device, then
    return to camera. Press a volume button again to confirm.";
  - count == 0 → "No lightning detected. Return to camera without saving?".
- Confirm: pop dialog → `await lightningDetectionService.whenScanComplete()`
  (with a blocking progress dialog if still scanning) → `_saveImages(hits)`
  (skipped when zero) → `_returnToCamera()` (existing path: clears cache,
  pops route — and `reset()` the detection service).
- Cancel / tap-outside / back: `_volumeDialogOpen = false`; flow re-arms.

## Settings (`lib/settings/settings_manager.dart` + `settings_page.dart`)

One new persisted `double`, following the existing slider-setting pattern
(`_maxStrikeDistanceKm` is the closest template):

- Key `lightning_confidence_threshold`; bounds
  `static const double minLightningThreshold = 0.10`,
  `maxLightningThreshold = 0.90`; signal `_lightningThreshold` (default `0.55`,
  clamped on load); getter `lightningThreshold`, signal getter
  `lightningThresholdSignal`; setter `setLightningThreshold(double)` (clamps and
  persists).
- The detection service and gallery read `lightningThresholdSignal` so a change
  recomputes hits reactively (R7).

Two sliders write this one setter, so they stay in sync with no extra wiring:

1. **Settings page** — a new `ListTile` with a `Slider` (mirrors "Overlay
   strike distance"), in a `SignalBuilder`. Title "Lightning sensitivity",
   subtitle explaining lower = more (including false) detections, higher = only
   obvious bolts. `Slider` min/max from the constants, ~16 divisions, label and
   trailing show the value as a percentage (e.g. "55%"); `onChanged` →
   `setLightningThreshold`.
2. **Gallery page** — the in-place control described under "Gallery sensitivity
   control (R7)", for tuning against the live captured frames.

No on/off toggle — detection always runs (a non-goal); the slider only tunes
sensitivity.

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
| User deletes hit frames mid-scan | Results keyed by sequence number — no misattribution; counts recompute from surviving images |
| Zero lightning found | Top section hidden; save-lightning button disabled; volume flow offers plain exit |
| User moves threshold slider | Hits recomputed from stored confidences — top section, badges, and counts update with no rescan |
