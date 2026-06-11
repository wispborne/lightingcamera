# Lightning Detection in Gallery

Automatically classify captured frames for lightning when the gallery opens, highlight the hits, and offer fast save-only-lightning actions (app-bar button and volume-key double-press).

## Requirements

### R1: Automatic scan on gallery open

When the gallery opens with a captured buffer, every frame MUST be scanned for lightning by an on-device classifier, in the background, without blocking the grid.

#### Acceptance
- Scanning starts automatically when the gallery page opens; no user action required.
- The grid renders and stays interactive (scroll, pinch-zoom, selection) while the scan runs.
- A scan runs entirely on-device; no network access.
- Results arrive progressively — a frame's flag appears as soon as that frame is classified, not after the whole scan.
- A frame is flagged when the classifier's "Lightning" confidence meets a threshold defined as a single named constant.
- Deleting frames (delete/keep selected) does not misattribute results: flags stay attached to their image (keyed by the frame's sequence number, not its grid index).
- The scan stops and discards results when the user leaves the gallery.

### R2: Highlighting flagged frames

Frames flagged as containing lightning MUST be visually distinct in the grid, and scan progress MUST be visible while detection is incomplete.

#### Acceptance
- A flagged thumbnail shows a clearly visible marker (border + bolt badge) in both normal and selection modes, without obscuring the image.
- Markers appear live as the scan progresses.
- While scanning, an unobtrusive progress indicator (e.g. "Scanning 37/100" or a small spinner with count) is visible; it disappears when the scan completes.
- Unflagged frames look exactly as they do today.

### R3: Save-lightning app-bar action

The gallery app bar MUST offer an action that saves only the flagged images to the device.

#### Acceptance
- The action shows the current flagged count (e.g. badge or "Save lightning (N)" tooltip/label) and updates as the scan progresses.
- Disabled when zero frames are flagged; enabled as soon as one is.
- Tapping it saves exactly the flagged images using the existing save pipeline (same permission handling, JPEG quality, and success/failure snackbar as "Save all").
- The existing "Save all" action remains available and unchanged.
- A save in progress shows the same busy state pattern as "Save all" and prevents double-triggering.

### R4: Volume-key save-and-exit

While the gallery page is visible, a volume-key press MUST start a two-step save-and-exit flow: first press informs/confirms, second press saves all flagged images and closes the gallery.

#### Acceptance
- First volume press (up or down) opens a dialog stating how many lightning images will be saved and that the gallery will close; it offers Cancel and an on-screen confirm as well.
- A second volume press while the dialog is open confirms: all flagged images are saved, then the gallery pops back to the camera (cache cleared, same path as the normal exit).
- Confirming via the dialog's on-screen button behaves identically to the second volume press.
- If the scan is still running at confirm time, the save waits for the scan to finish (dialog shows progress) so no late-flagged frame is missed.
- If zero frames are flagged, the dialog says so; confirming simply closes the gallery without saving.
- Cancel (button, tap-outside, or back) dismisses the dialog and resets the flow — the next volume press starts again at step one.
- Volume presses on the gallery never alter system volume and never trigger the camera shutter.

### R5: Camera shutter regression guard

Refactoring volume-key delivery MUST NOT change camera-page behavior.

#### Acceptance
- On the camera page, a volume press still triggers the shutter exactly as before (including the existing debounce and page-visibility rules).
- After opening the gallery and returning to the camera, the volume shutter still works.
- Volume presses while the app is backgrounded or another page is on top affect neither page.
