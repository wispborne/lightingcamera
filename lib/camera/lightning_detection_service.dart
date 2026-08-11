import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:signals/signals.dart';

import 'image_cache_manager.dart';
import 'image_converter.dart';
import 'yuv_conversion_pool.dart';

final lightningDetectionService = LightningDetectionService();

/// One frame packed for the labeler: the [InputImage] (null if the frame
/// couldn't be converted) and whether the pool cancelled the request.
typedef _PreparedFrame = ({InputImage? image, bool cancelled});

/// Runs Google ML Kit's on-device image labeler over a frozen capture buffer
/// and reports, per frame, how confident it is that the frame shows lightning.
///
/// The raw confidence for *every* scanned frame is kept (keyed by the frame's
/// sequence number, so results survive grid deletions/reindexing). Whether a
/// frame is a "hit" is derived live from the user's threshold setting — so
/// dragging the sensitivity slider re-filters results with no rescan.
class LightningDetectionService {
  /// The base model's label for lightning. Matched case-insensitively.
  static const _lightningLabel = 'lightning';

  /// sequenceNumber → "Lightning" confidence (0–1). Every scanned frame is
  /// recorded, including `0.0` for frames the labeler found no lightning in.
  final confidences = mapSignal<int, double>({});

  final _scannedCount = signal(0);
  final _totalCount = signal(0);
  ReadonlySignal<int> get scannedCount => _scannedCount;
  ReadonlySignal<int> get totalCount => _totalCount;
  late final ReadonlySignal<bool> isScanning = computed(
    () => _scannedCount.value < _totalCount.value,
  );

  ImageLabeler? _labeler;

  /// Bumped on [reset] so an in-flight [scan] loop knows to stop.
  int _generation = 0;

  /// Completes when the current scan finishes; null while idle.
  Completer<void>? _scanCompleter;

  /// Whether [sequenceNumber]'s recorded confidence clears the current
  /// threshold. Reads both [confidences] and the threshold signal, so callers
  /// inside a `SignalBuilder` rebuild when either changes.
  bool isHit(int sequenceNumber) {
    final confidence = confidences.value[sequenceNumber];
    if (confidence == null) return false;
    return confidence >= settingsManager.lightningThresholdSignal.value;
  }

  /// The given [frames] whose confidence clears the threshold, most confident
  /// first. Reads [confidences] and the threshold signal so a `SignalBuilder`
  /// using it re-filters and re-sorts live.
  List<ImageWithMetadata> hitsByConfidence(List<ImageWithMetadata> frames) {
    final threshold = settingsManager.lightningThresholdSignal.value;
    final scored = frames
        .where((f) => (confidences.value[f.sequenceNumber] ?? 0) >= threshold)
        .toList();
    scored.sort((a, b) {
      final ca = confidences.value[a.sequenceNumber] ?? 0;
      final cb = confidences.value[b.sequenceNumber] ?? 0;
      return cb.compareTo(ca);
    });
    return scored;
  }

  /// Raw recorded confidence for a frame, or `null` if not yet scanned.
  double? confidenceFor(int sequenceNumber) => confidences.value[sequenceNumber];

  ImageLabeler _ensureLabeler() {
    // Pin the labeler's own confidence floor at the slider minimum so every
    // selectable threshold has data to filter against.
    return _labeler ??= ImageLabeler(
      options: ImageLabelerOptions(
        confidenceThreshold: SettingsManager.minLightningThreshold,
      ),
    );
  }

  /// Classify every frame in [frames], recording each one's lightning
  /// confidence as it completes. NV21 packing is pipelined one frame ahead of
  /// the labeler: while ML Kit processes frame N, frame N+1's bytes are
  /// already being packed in the conversion pool, so neither stage waits on
  /// the other. Safe to leave running — [reset] cancels it.
  ///
  /// With [keepResults] the recorded confidences survive and already-scanned
  /// frames are skipped. The gallery uses this to resume after a deletion:
  /// deleting cancels all queued pool work, which stops the running scan loop,
  /// so the survivors that weren't scanned yet need a fresh one.
  Future<void> scan(
    List<ImageWithMetadata> frames, {
    bool keepResults = false,
  }) async {
    final gen = ++_generation;
    if (!keepResults) confidences.clear();
    final toScan = keepResults
        ? frames
            .where((f) => !confidences.value.containsKey(f.sequenceNumber))
            .toList()
        : frames;
    _scannedCount.value = frames.length - toScan.length;
    _totalCount.value = frames.length;
    final completer = Completer<void>();
    _scanCompleter = completer;

    final labeler = _ensureLabeler();

    Future<_PreparedFrame>? pending;
    for (int i = 0; i < toScan.length; i++) {
      if (gen != _generation) break;
      final frame = toScan[i];
      final prepared = await (pending ?? _prepare(frame));
      if (gen != _generation) break;
      // Kick off the next frame's packing before the (slow) labeler call so
      // the two overlap. _prepare never throws, so abandoning this future on
      // break/reset leaks no unhandled error.
      pending = i + 1 < toScan.length ? _prepare(toScan[i + 1]) : null;
      if (prepared.cancelled) break;

      double confidence = 0.0;
      if (prepared.image != null) {
        try {
          final labels = await labeler.processImage(prepared.image!);
          if (gen != _generation) break;
          for (final label in labels) {
            if (label.label.toLowerCase() == _lightningLabel) {
              confidence = label.confidence;
              break;
            }
          }
        } catch (e) {
          Fimber.e(
              'Lightning scan failed for frame ${frame.sequenceNumber}: $e',
              ex: e);
        }
      }
      if (gen != _generation) break;
      confidences[frame.sequenceNumber] = confidence;
      _scannedCount.value = _scannedCount.value + 1;
    }

    if (gen == _generation) {
      _scanCompleter = null;
    }
    if (!completer.isCompleted) completer.complete();
  }

  /// Completes when the in-progress scan finishes (immediately if idle). Used
  /// by the gallery's save-and-exit flow so no late-flagged frame is missed.
  Future<void> whenScanComplete() async {
    final completer = _scanCompleter;
    if (completer == null) return;
    await completer.future;
  }

  /// Cancel any running scan, drop all results, and free the native labeler.
  void reset() {
    _generation++;
    final completer = _scanCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    _scanCompleter = null;
    confidences.clear();
    _scannedCount.value = 0;
    _totalCount.value = 0;
    _labeler?.close();
    _labeler = null;
  }

  /// Packs [frame] into an ML Kit [InputImage], swallowing failures:
  /// `cancelled` means the pool dropped the request (the scan should stop), a
  /// null image means the frame couldn't be converted (record no lightning
  /// and move on). Never throws, so [scan] can safely fire-and-forget it one
  /// frame ahead.
  Future<_PreparedFrame> _prepare(ImageWithMetadata frame) async {
    try {
      return (image: await _toInputImage(frame), cancelled: false);
    } on YuvCancelledException {
      // The gallery is tearing down the pool — stop scanning.
      return (image: null, cancelled: true);
    } catch (e) {
      Fimber.e('Lightning scan failed for frame ${frame.sequenceNumber}: $e',
          ex: e);
      return (image: null, cancelled: false);
    }
  }

  /// Wraps a cached YUV420 frame as an ML Kit [InputImage] (NV21 bytes,
  /// downscaled to thumbnail size — plenty for the labeler's ~224px model
  /// input), or `null` if the frame is not YUV420. The NV21 packing runs in
  /// the shared conversion pool at low priority so it never delays gallery
  /// thumbnails.
  Future<InputImage?> _toInputImage(ImageWithMetadata frame) async {
    final image = frame.image;
    if (image.format.group != ImageFormatGroup.yuv420) return null;

    final packed = await yuvConversionPool.convert(
      YuvConversionRequest.nv21(frame),
      priority: ConversionPriority.low,
    );
    return InputImage.fromBytes(
      bytes: packed.bytes,
      metadata: InputImageMetadata(
        size: Size(packed.width.toDouble(), packed.height.toDouble()),
        rotation: _rotationFor(frame.orientation, frame.lensDirection),
        format: InputImageFormat.nv21,
        bytesPerRow: packed.width,
      ),
    );
  }

  /// Maps the frame's device orientation and lens to the ML Kit rotation that
  /// makes the image upright, reusing [ImageConverter]'s display-path angles.
  InputImageRotation _rotationFor(
    DeviceOrientation orientation,
    CameraLensDirection lensDirection,
  ) {
    switch (ImageConverter.rotationFor(orientation, lensDirection)) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }
}
