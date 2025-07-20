import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:lightingcamera/native/yuv_converter_ffi.dart';

import 'image_cache_manager.dart';

/// An image that has been processed and is ready for display or saving.
class ProcessedImage {
  final img.Image image;

  ProcessedImage(this.image);

  Uint8List? _cachedDisplayableBytes;
  Future<Uint8List>? _displayableBytesCache;

  Future<Uint8List> get displayableBytes {
    // Return existing cache if available
    if (_displayableBytesCache != null) {
      return _displayableBytesCache!;
    }

    // If we have cached bytes, return them immediately
    if (_cachedDisplayableBytes != null) {
      return Future.value(_cachedDisplayableBytes!);
    }

    // Create and cache the future
    _displayableBytesCache = _computeDisplayableBytes();
    return _displayableBytesCache!;
  }

  Future<Uint8List> _computeDisplayableBytes() async {
    // Perform the expensive operation on a separate isolate/compute
    final bytes = await compute(_encodeImage, image);
    _cachedDisplayableBytes = bytes;
    return bytes;
  }

  // Static function for compute
  static Uint8List _encodeImage(dynamic image) {
    return img.encodeJpg(image);
  }
}

class ImageConverter {
  /// Processes an [ImageWithMetadata] to a displayable and saveable format.
  ///
  /// This method converts the YUV420 image from the camera into a standard
  /// RGB format, applies the correct rotation to match the CameraPreview widget,
  /// and returns an object that can be displayed or saved.
  static ProcessedImage processImage(ImageWithMetadata imageWithMetadata) {
    final cameraImage = imageWithMetadata.image;

    // Apply rotation to match what CameraPreview shows
    // The rotation logic needs to account for both device orientation AND camera type
    double rotationAngle = _getRotationAngle(
      imageWithMetadata.orientation,
      imageWithMetadata.lensDirection,
    );

    // Convert YUV to RGB
    img.Image rgbImage = _convertYuvToRgbOptimized(
      cameraImage,
      rotationAngle.toInt(),
    );

    // if (rotationAngle != 0) {
    //   rgbImage = img.copyRotate(rgbImage, angle: rotationAngle);
    // }

    return ProcessedImage(rgbImage);
  }

  /// Determines the rotation angle needed to match CameraPreview orientation.
  /// This logic accounts for both device orientation and camera type (front/back).
  static double _getRotationAngle(
    DeviceOrientation orientation,
    CameraLensDirection lensDirection,
  ) {
    // Back camera and front camera have different sensor orientations
    // Front camera images are also mirrored horizontally by CameraPreview

    if (lensDirection == CameraLensDirection.back) {
      // Back camera rotation logic
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          return 90;
        case DeviceOrientation.portraitDown:
          return -90;
        case DeviceOrientation.landscapeLeft:
          return 0;
        case DeviceOrientation.landscapeRight:
          return 180;
      }
    } else {
      // Front camera rotation logic (different from back camera)
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          return -90; // Different from back camera
        case DeviceOrientation.portraitDown:
          return 90; // Different from back camera
        case DeviceOrientation.landscapeLeft:
          return 0; // Different from back camera
        case DeviceOrientation.landscapeRight:
          return 180; // Different from back camera
      }
    }
  }

  /// Uses native C for the conversion.
  static img.Image _convertYuvToRgbOptimized(
    CameraImage cameraImage,
    int rotation,
  ) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;

    final Uint8List yPlane = cameraImage.planes[0].bytes;
    final Uint8List uPlane = cameraImage.planes[1].bytes;
    final Uint8List vPlane = cameraImage.planes[2].bytes;

    final int uvRowStride = cameraImage.planes[1].bytesPerRow;
    final int uvPixelStride = cameraImage.planes[1].bytesPerPixel!;

    // Use native FFI conversion
    final Uint8List rgbData = YuvConverterFFI.convertYuvToRgb(
      yPlane,
      uPlane,
      vPlane,
      width,
      height,
      uvRowStride,
      uvPixelStride,
      rotation,
    );

    // Dimensions of the possibly-rotated output image
    final int destWidth = (rotation == 90 || rotation == 270) ? height : width;
    final int destHeight = (rotation == 90 || rotation == 270) ? width : height;

    return img.Image.fromBytes(
      width: destWidth,
      height: destHeight,
      bytes: rgbData.buffer,
      order: img.ChannelOrder.rgb,
    );
  }

  /// Converts a [CameraImage] in YUV420 format to a `img.Image` in RGB format.
  ///
  /// Note: This is a pure Dart implementation and is slow.
  static img.Image _convertYuvToRgbDart(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;

    final image = img.Image(width: width, height: height);

    final Uint8List yPlane = cameraImage.planes[0].bytes;
    final Uint8List uPlane = cameraImage.planes[1].bytes;
    final Uint8List vPlane = cameraImage.planes[2].bytes;

    final int uvRowStride = cameraImage.planes[1].bytesPerRow;
    final int uvPixelStride = cameraImage.planes[1].bytesPerPixel!;

    // Pre-calculate lookup tables for better performance
    final List<int> yLookup = List.generate(256, (i) => i);
    final List<int> uLookup = List.generate(256, (i) => i - 128);
    final List<int> vLookup = List.generate(256, (i) => i - 128);

    const int c_v_r = 1436;
    const int c_u_g = 46549;
    const int c_v_g = 93604;
    const int c_u_b = 1814;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
        final int yIndex = y * width + x;

        final int yp = yLookup[yPlane[yIndex]];
        final int up = uLookup[uPlane[uvIndex]];
        final int vp = vLookup[vPlane[uvIndex]];

        // YUV to RGB conversion
        final int r = _clampValue(0, 255, yp + (vp * c_v_r) ~/ 1024);
        final int g = _clampValue(
          0,
          255,
          yp - (up * c_u_g) ~/ 131072 - (vp * c_v_g) ~/ 131072,
        );
        final int b = _clampValue(0, 255, yp + (up * c_u_b) ~/ 1024);

        image.setPixelRgb(x, y, r, g, b);
      }
    }

    return image;
  }

  /// Clamps [val] between [lower] and [higher].
  /// Returns [lower] if [val] < [lower], [higher] if [val] > [higher], else [val].
  static int _clampValue(int lower, int higher, int val) {
    if (val < lower) return lower;
    if (val > higher) return higher;
    return val;
  }
}
