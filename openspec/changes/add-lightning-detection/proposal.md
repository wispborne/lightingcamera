# Lightning Detection in Gallery

## Problem

After a capture, the gallery holds up to 100 near-identical frames and the user has to eyeball every thumbnail to find the handful that actually contain a bolt. That's slow, error-prone on a small grid, and painful mid-storm when the user wants to free the buffer and get back to shooting as fast as possible. "Save all" wastes storage on 95 empty sky frames; manual selection wastes time.

## Proposed Solution

Run an on-device image classifier over the captured buffer when the gallery opens, and build the workflow around its results:

- **Detection: Google ML Kit image labeling (base model).** Runs fully on-device, needs no API key, no network, and no custom training — its built-in label set includes "Lightning". Frames are scanned progressively in the background as the gallery opens; each frame whose "Lightning" confidence clears a threshold is flagged.
- **Highlighting.** Flagged thumbnails get a clear visual marker (colored border + bolt badge) that appears live as the scan progresses. A small scan-progress indicator shows while detection is running.
- **One-tap save.** A new app-bar button ("Save lightning (N)") saves only the flagged images to the device, reusing the existing save pipeline. Enabled as soon as at least one frame is flagged.
- **Volume-button quick exit.** While the gallery is open, the first volume-key press shows a confirmation/info dialog ("Save N lightning images and return to camera?"); a second volume-key press confirms — the flagged images are saved and the gallery closes back to the camera. This gives a no-look, gloves-on path from "buffer captured" to "back to shooting" in two clicks.

## Scope

- New `LightningDetectionService` wrapping ML Kit image labeling, scanning the frozen buffer and exposing per-frame results as signals.
- YUV420 → NV21 conversion so cached camera frames can feed ML Kit directly (no JPEG round-trip).
- Gallery grid highlighting + scan progress indicator.
- "Save lightning" app-bar action (filters the existing save-all flow).
- Shared volume-key dispatcher so the gallery can receive volume presses without breaking the camera page's shutter handler; double-press save-and-exit flow with confirmation dialog.
- New dependency: `google_mlkit_image_labeling`.

## Non-Goals

- Custom-trained lightning model (the service isolates the classifier so one can be swapped in later if the base model underperforms).
- Detection during live capture / on the camera page — scanning happens only on the frozen buffer in the gallery.
- Bolt localization (bounding boxes) — frame-level yes/no only.
- Auto-deleting non-lightning frames.
- A settings toggle for detection — it always runs; it's passive until the user acts on it.

## Risks / Open Questions

- **Base-model accuracy.** ML Kit's generic model may miss faint or partially-occluded bolts and may false-positive on bright point lights at night. Mitigations: confidence threshold is a single tunable constant; highlighting is additive (user can still select/save manually); the detector lives behind one service interface so a custom TFLite model can replace it without touching the UI.
- **Scan time.** ~100 frames at tens of ms each means a full scan can take several seconds on slower devices. Mitigated by progressive results (badges appear as found) and by scanning newest-first is not needed — order matches the grid so visible tiles resolve early.
- **Volume-channel ownership.** Android delivers volume keys to a single method channel currently handled by the camera page. Moving to a shared dispatcher must not regress the camera shutter (covered by explicit acceptance criteria).
