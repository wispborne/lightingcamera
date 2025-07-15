import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'image_cache_manager.dart';

/// An image that has been processed and is ready for display or saving.
class ProcessedImage {
  final img.Image image;

  ProcessedImage(this.image);

  /// Returns the image as PNG-encoded bytes.
  ///
  /// This can be used with Flutter's `Image.memory` widget for display.
  Uint8List get displayableBytes => img.encodePng(image);
}

class ImageConverter {
  /// Processes an [ImageWithMetadata] to a displayable and saveable format.
  ///
  /// This method converts the YUV420 image from the camera into a standard
  /// RGB format, applies the correct rotation to match the CameraPreview widget,
  /// and returns an object that can be displayed or saved.
  static ProcessedImage processImage(ImageWithMetadata imageWithMetadata) {
    final cameraImage = imageWithMetadata.image;

    // Convert YUV to RGB
    img.Image rgbImage = _convertYuvToRgb(cameraImage);

    // Apply rotation to match what CameraPreview shows
    // The rotation logic needs to account for both device orientation AND camera type
    double rotationAngle = _getRotationAngle(
      imageWithMetadata.orientation,
      imageWithMetadata.lensDirection,
    );

    if (rotationAngle != 0) {
      rgbImage = img.copyRotate(rgbImage, angle: rotationAngle);
    }

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
          return 180;
        case DeviceOrientation.landscapeRight:
          return 0;
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

  /// Converts a [CameraImage] in YUV420 format to a `img.Image` in RGB format.
  ///
  /// Note: This is a pure Dart implementation and might be slow.
  static img.Image _convertYuvToRgb(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;

    final image = img.Image(width: width, height: height);

    final Uint8List yPlane = cameraImage.planes[0].bytes;
    final Uint8List uPlane = cameraImage.planes[1].bytes;
    final Uint8List vPlane = cameraImage.planes[2].bytes;

    final int uvRowStride = cameraImage.planes[1].bytesPerRow;
    final int uvPixelStride = cameraImage.planes[1].bytesPerPixel!;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
        final int yIndex = y * width + x;

        final int yp = yPlane[yIndex];
        final int up = uPlane[uvIndex];
        final int vp = vPlane[uvIndex];

        // YUV to RGB conversion formula from the original `convertImage`
        final int rt = (yp + vp * 1436 / 1024 - 179).round();
        final int gt =
            (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round();
        final int bt = (yp + up * 1814 / 1024 - 227).round();

        final int r = _clampValue(0, 255, rt);
        final int g = _clampValue(0, 255, gt);
        final int b = _clampValue(0, 255, bt);

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

  /// Calculates the byte index for a 90°-rotated image at (x, y) given [rotatedImageWidth].
  static int _getRotatedImageByteIndex(int x, int y, int rotatedImageWidth) {
    return rotatedImageWidth * (y + 1) - (x + 1);
  }
}
