import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:signals/signals.dart';

import 'image_cache_manager.dart';

final lightningDetectionService = LightningDetectionService();

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

  /// Classify every frame in [frames] sequentially, recording each one's
  /// lightning confidence as it completes. Safe to leave running — [reset]
  /// cancels it.
  Future<void> scan(List<ImageWithMetadata> frames) async {
    final gen = ++_generation;
    confidences.clear();
    _scannedCount.value = 0;
    _totalCount.value = frames.length;
    final completer = Completer<void>();
    _scanCompleter = completer;

    final labeler = _ensureLabeler();

    for (final frame in frames) {
      if (gen != _generation) break;
      double confidence = 0.0;
      try {
        final inputImage = _toInputImage(frame);
        if (inputImage != null) {
          final labels = await labeler.processImage(inputImage);
          if (gen != _generation) break;
          for (final label in labels) {
            if (label.label.toLowerCase() == _lightningLabel) {
              confidence = label.confidence;
              break;
            }
          }
        }
      } catch (e) {
        Fimber.e('Lightning scan failed for frame ${frame.sequenceNumber}: $e',
            ex: e);
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

  /// Wraps a cached YUV420 frame as an ML Kit [InputImage] (NV21 bytes), or
  /// `null` if the frame is not YUV420.
  InputImage? _toInputImage(ImageWithMetadata frame) {
    final image = frame.image;
    if (image.format.group != ImageFormatGroup.yuv420) return null;

    final nv21 = _yuv420ToNv21(image);
    return InputImage.fromBytes(
      bytes: nv21,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotationFor(frame.orientation, frame.lensDirection),
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      ),
    );
  }

  /// Packs a 3-plane YUV420 [image] into a single NV21 buffer: the Y plane
  /// (row-stride stripped to width) followed by interleaved V/U chroma.
  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int chromaWidth = (width + 1) ~/ 2;
    final int chromaHeight = (height + 1) ~/ 2;

    final nv21 = Uint8List(width * height + 2 * chromaWidth * chromaHeight);

    // Y plane, dropping any row padding.
    final yPlane = image.planes[0];
    final yBytes = yPlane.bytes;
    final int yRowStride = yPlane.bytesPerRow;
    int offset = 0;
    if (yRowStride == width) {
      nv21.setRange(0, width * height, yBytes);
      offset = width * height;
    } else {
      for (int row = 0; row < height; row++) {
        final int rowStart = row * yRowStride;
        nv21.setRange(offset, offset + width, yBytes, rowStart);
        offset += width;
      }
    }

    // Chroma: NV21 wants V then U, interleaved. Handle both planar
    // (pixelStride 1) and semi-planar (pixelStride 2) source layouts.
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int row = 0; row < chromaHeight; row++) {
      int uvIndex = row * uvRowStride;
      for (int col = 0; col < chromaWidth; col++) {
        nv21[offset++] = vBytes[uvIndex];
        nv21[offset++] = uBytes[uvIndex];
        uvIndex += uvPixelStride;
      }
    }

    return nv21;
  }

  /// Maps the frame's device orientation and lens to the ML Kit rotation that
  /// makes the image upright, mirroring [ImageConverter]'s display-path angles.
  InputImageRotation _rotationFor(
    DeviceOrientation orientation,
    CameraLensDirection lensDirection,
  ) {
    int angle;
    if (lensDirection == CameraLensDirection.back) {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          angle = 90;
        case DeviceOrientation.portraitDown:
          angle = 270;
        case DeviceOrientation.landscapeLeft:
          angle = 0;
        case DeviceOrientation.landscapeRight:
          angle = 180;
      }
    } else {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          angle = 270;
        case DeviceOrientation.portraitDown:
          angle = 90;
        case DeviceOrientation.landscapeLeft:
          angle = 0;
        case DeviceOrientation.landscapeRight:
          angle = 180;
      }
    }
    switch (angle) {
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
