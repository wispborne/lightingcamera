import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// A converted frame ready for display: RGBA pixel bytes plus the lazily-decoded
/// [ui.Image] texture. The bytes can be released once the texture exists to keep
/// memory low — thumbnails do this so a full buffer of them stays cheap.
class ProcessedFrame {
  ProcessedFrame(this._rgba, this.width, this.height);

  final int width;
  final int height;

  Uint8List? _rgba;
  ui.Image? _uiImage;
  Future<ui.Image>? _uiImageFuture;
  bool _disposed = false;

  /// The decoded texture, or null until [uiImage] has resolved at least once.
  /// Callers that only add a frame to their state after awaiting [uiImage] can
  /// read this directly instead of going back through the future.
  ui.Image? get image => _uiImage;

  /// Decodes the RGBA bytes into a [ui.Image] once and caches the result.
  Future<ui.Image> get uiImage {
    if (_disposed) throw StateError('ProcessedFrame has been disposed');
    return _uiImageFuture ??= _decode();
  }

  Future<ui.Image> _decode() {
    final bytes = _rgba;
    if (bytes == null) {
      throw StateError('ProcessedFrame bytes were released before decoding');
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image result) {
        _uiImage = result;
        completer.complete(result);
      },
    );
    return completer.future;
  }

  /// Drops the CPU-side RGBA buffer. Safe to call after [uiImage] has resolved —
  /// the texture lives on the GPU from then on.
  void releaseBytes() => _rgba = null;

  void dispose() {
    _disposed = true;
    _rgba = null;
    _uiImage?.dispose();
    _uiImage = null;
  }
}

class ImageConverter {
  /// The rotation, in degrees, needed to make a captured frame upright to match
  /// what `CameraPreview` shows. Accounts for both device orientation and lens
  /// (front-facing sensors are mounted the opposite way). Always normalized to
  /// one of 0/90/180/270 so the native converter's rotation switch never falls
  /// through (a raw -90 used to be silently treated as 0).
  static int rotationFor(
    DeviceOrientation orientation,
    CameraLensDirection lensDirection,
  ) {
    int angle;
    if (lensDirection == CameraLensDirection.back) {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          angle = 90;
        case DeviceOrientation.portraitDown:
          angle = -90;
        case DeviceOrientation.landscapeLeft:
          angle = 0;
        case DeviceOrientation.landscapeRight:
          angle = 180;
      }
    } else {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          angle = -90;
        case DeviceOrientation.portraitDown:
          angle = 90;
        case DeviceOrientation.landscapeLeft:
          angle = 0;
        case DeviceOrientation.landscapeRight:
          angle = 180;
      }
    }
    return ((angle % 360) + 360) % 360;
  }

  /// The integer downscale factor for a grid thumbnail of a [srcWidth] ×
  /// [srcHeight] frame. Targets roughly 360px on the short side — sharp enough
  /// for the densest grid while doing a fraction of the conversion work and
  /// holding a fraction of the texture memory of a full-resolution frame.
  static int thumbScaleFor(int srcWidth, int srcHeight) {
    final shortSide = srcWidth < srcHeight ? srcWidth : srcHeight;
    final scale = shortSide ~/ 360;
    return scale < 1 ? 1 : scale;
  }
}
