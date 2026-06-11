# Tasks — Lightning Detection in Gallery

- [ ] Add `google_mlkit_image_labeling` to `pubspec.yaml` (`fvm flutter pub add google_mlkit_image_labeling`) and confirm `android/app/build.gradle.kts` has `minSdk ≥ 21`.
- [ ] Create `lib/utils/volume_key_dispatcher.dart`: singleton owning the `com.wisp.lightingcamera/volume_keys` channel with a listener stack (`subscribe`/`unsubscribe`, top listener wins).
- [ ] Migrate `camera_page.dart` to the dispatcher (subscribe in `initState`, unsubscribe in `dispose`, keep `_volumeButtonsEnabled`/visibility/debounce logic inside the listener); delete its direct `MethodChannel` handler.
- [ ] Create `lib/camera/lightning_detection_service.dart`: `lightningDetectionService` singleton with `confidences` map signal (keyed by sequence number), `scannedCount`/`totalCount`/`isScanning` signals, generation-based `reset()`, `whenScanComplete()`, and `kLightningConfidenceThreshold`.
- [ ] Implement YUV420 → NV21 conversion (row-stride-aware Y copy, V/U interleave handling pixel stride 1 and 2) and `InputImage.fromBytes` metadata incl. rotation derived from frame orientation + lens direction.
- [ ] Implement the sequential `scan()` loop: label each frame, record flagged confidences, count errors as scanned, log failures with `Fimber.e`, abort cleanly on generation change.
- [ ] Gallery: start `scan(images)` in `initState`; call `reset()` in `dispose` and `_returnToCamera()`.
- [ ] Gallery grid: amber border + top-left `Icons.bolt` badge on flagged tiles via `SignalBuilder`, coexisting with selection overlay/checkmark.
- [ ] Gallery app bar: scan `LinearProgressIndicator` as `AppBar.bottom` while scanning (via `SignalBuilder`).
- [ ] Refactor `_saveAll` into shared `_saveImages(List<ImageWithMetadata>)` helper (permissions, convert-or-reuse, JPEG 95, snackbar); `_saveAll` delegates to it; unify the busy flag so concurrent saves are impossible.
- [ ] Gallery app bar: add `Badge.count` + `Icons.bolt` "Save lightning (N)" button calling `_saveImages` with flagged images; disabled at zero or while saving.
- [ ] Gallery volume flow: subscribe to dispatcher; first press opens the confirm dialog (states flagged count, scan progress when running, zero-found wording); second press or on-screen confirm → `whenScanComplete()` → save flagged → `_returnToCamera()`; cancel re-arms.
- [ ] `fvm flutter analyze` clean (no new warnings).
- [ ] On-device check (manual): scan flags real lightning frames and badges appear progressively; "Save lightning" saves only flagged images; volume double-press saves and exits to a working camera page; camera volume shutter still fires before and after a gallery visit; system volume UI never appears.
