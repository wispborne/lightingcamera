# Lightning Detection in Gallery

## Problem

After a capture, the gallery holds up to 100 near-identical frames and the user has to eyeball every thumbnail to find the handful that actually contain a bolt. That's slow, error-prone on a small grid, and painful mid-storm when the user wants to free the buffer and get back to shooting as fast as possible. "Save all" wastes storage on 95 empty sky frames; manual selection wastes time.

## Proposed Solution

Run an on-device image classifier over the captured buffer when the gallery opens, and build the workflow around its results:

- **Detection: Google ML Kit image labeling (base model).** Runs fully on-device, needs no API key, no network, and no custom training — its built-in label set includes "Lightning". Frames are scanned progressively in the background as the gallery opens; the scanner records the "Lightning" confidence for every frame, and a frame counts as a hit when its confidence clears the user's threshold.
- **Lightning section at the top.** A dedicated section above the main grid shows just the detected frames, sorted by confidence (highest first), so the best shots surface immediately without scrolling 100 near-identical tiles. It fills in live as the scan progresses and re-sorts/re-filters instantly when the threshold changes.
- **Highlighting.** Detected thumbnails in the main grid also get a clear visual marker (colored border + bolt badge) that appears live as the scan progresses. A small scan-progress indicator shows while detection is running.
- **One-tap save.** A new app-bar button ("Save lightning (N)") saves only the detected images to the device, reusing the existing save pipeline. Enabled as soon as at least one frame is a hit.
- **Volume-button quick exit.** While the gallery is open, the first volume-key press shows a confirmation/info dialog ("Save N lightning images and return to camera?"); a second volume-key press confirms — the detected images are saved and the gallery closes back to the camera. This gives a no-look, gloves-on path from "buffer captured" to "back to shooting" in two clicks.
- **Adjustable sensitivity, tunable in place.** A confidence-threshold slider (default 0.55) lives both on the settings page and on the gallery page itself, so the user can drag it while watching the top section, badges, and save count re-filter live against the real captured frames. Lower it to catch faint bolts (more false positives), raise it to keep only obvious strikes. Both sliders bind to one persisted setting, so they stay in sync. Because the scanner keeps every frame's raw confidence, moving the slider never triggers a rescan.

## Scope

- New `LightningDetectionService` wrapping ML Kit image labeling, scanning the frozen buffer and exposing every frame's confidence as signals; the hit set is derived live from the threshold setting.
- YUV420 → NV21 conversion so cached camera frames can feed ML Kit directly (no JPEG round-trip).
- Gallery "Lightning" section at the top, sorted by confidence, plus main-grid highlighting + scan progress indicator.
- "Save lightning" app-bar action (filters the existing save-all flow).
- Shared volume-key dispatcher so the gallery can receive volume presses without breaking the camera page's shutter handler; double-press save-and-exit flow with confirmation dialog.
- New persisted `lightning_confidence_threshold` setting with a slider on both the settings page and the gallery page (bound to the same setting).
- New dependency: `google_mlkit_image_labeling`.

## Non-Goals

- Custom-trained lightning model (the service isolates the classifier so one can be swapped in later if the base model underperforms).
- Detection during live capture / on the camera page — scanning happens only on the frozen buffer in the gallery.
- Bolt localization (bounding boxes) — frame-level confidence only.
- Auto-deleting non-lightning frames.
- A settings toggle to turn detection off — it always runs; it's passive until the user acts on it. (The threshold slider tunes sensitivity but does not disable scanning.)

## Risks / Open Questions

- **Base-model accuracy.** ML Kit's generic model may miss faint or partially-occluded bolts and may false-positive on bright point lights at night. Mitigations: confidence threshold is a single tunable constant; highlighting is additive (user can still select/save manually); the detector lives behind one service interface so a custom TFLite model can replace it without touching the UI.
- **Scan time.** ~100 frames at tens of ms each means a full scan can take several seconds on slower devices. Mitigated by progressive results (badges appear as found) and by scanning newest-first is not needed — order matches the grid so visible tiles resolve early.
- **Volume-channel ownership.** Android delivers volume keys to a single method channel currently handled by the camera page. Moving to a shared dispatcher must not regress the camera shutter (covered by explicit acceptance criteria).
