import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img_lib;
import 'package:permission_handler/permission_handler.dart';

import 'image_cache_manager.dart';

class GalleryPage extends StatefulWidget {
  final List<ImageWithMetadata> images;
  final VoidCallback onBack;

  const GalleryPage({super.key, required this.images, required this.onBack});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  final Map<int, ui.Image> _displayImages = {};
  final Set<int> _currentlyConverting = {};
  final int _batchSize = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _convertImageBatch(0, _batchSize);
    });
  }

  Future<void> _convertImageBatch(int start, int count) async {
    final end = (start + count).clamp(0, widget.images.length);

    for (int i = start; i < end; i++) {
      if (_displayImages.containsKey(i) || _currentlyConverting.contains(i)) {
        continue;
      }

      _currentlyConverting.add(i);
      _convertSingleImage(i);
    }
  }

  Future<void> _convertSingleImage(int index) async {
    try {
      final timestampedImage = widget.images[index];
      final displayImage = await _convertCameraImageToUIImage(
        timestampedImage.image,
        timestampedImage.orientation,
      );

      if (mounted && displayImage != null) {
        setState(() {
          _displayImages[index] = displayImage;
          _currentlyConverting.remove(index);
        });
      }
    } catch (e) {
      print('Error converting image $index: $e');
      if (mounted) {
        _currentlyConverting.remove(index);
      }
    }
  }

  Future<ui.Image?> _convertCameraImageToUIImage(
    CameraImage cameraImage,
    DeviceOrientation orientation,
  ) async {
    try {
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        return await _yuv420ToUIImage(cameraImage, orientation);
      }
      return null;
    } catch (e) {
      print('Error in _convertCameraImageToUIImage: $e');
      return null;
    }
  }

  /// Converts a YUV420 [CameraImage] into a [ui.Image], applying the specified orientation.
  ///
  /// Params:
  ///  • cameraImage: the YUV420 image data from the device camera
  ///  • orientation: device orientation used to rotate the output image
  ///
  /// Returns a [ui.Image] in RGBA8888 format, or null if conversion fails.
  Future<ui.Image?> _yuv420ToUIImage(
    CameraImage cameraImage,
    DeviceOrientation orientation,
  ) async {
    // Calculate rotation angle based on orientation
    int rotationAngle = _getRotationAngle(orientation);

    // Determine dimensions after rotation
    final int srcWidth = cameraImage.width;
    final int srcHeight = cameraImage.height;
    final int width = _needsRotation(rotationAngle) ? srcHeight : srcWidth;
    final int height = _needsRotation(rotationAngle) ? srcWidth : srcHeight;

    // Create RGBA bytes (4 bytes per pixel)
    final rgbaBytes = Uint8List(width * height * 4);

    try {
      final int uvRowStride = cameraImage.planes[1].bytesPerRow;
      final int? pixelStrideNullable = cameraImage.planes[1].bytesPerPixel;
      if (pixelStrideNullable == null) {
        throw Exception('Unexpected null bytesPerPixel on UV plane');
      }
      final int uvPixelStride = pixelStrideNullable;

      final yPlane = cameraImage.planes[0].bytes;
      final uPlane = cameraImage.planes[1].bytes;
      final vPlane = cameraImage.planes[2].bytes;

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          // Calculate source coordinates based on rotation
          final coords = _rotateCoordinates(
            x,
            y,
            rotationAngle,
            width,
            height,
            srcWidth,
            srcHeight,
          );
          final int srcX = coords[0];
          final int srcY = coords[1];

          // Add bounds checking
          if (srcX < 0 || srcX >= srcWidth || srcY < 0 || srcY >= srcHeight) {
            // Fill with black if out of bounds
            final int rgbaIndex = (y * width + x) * 4;
            rgbaBytes[rgbaIndex] = 0;
            rgbaBytes[rgbaIndex + 1] = 0;
            rgbaBytes[rgbaIndex + 2] = 0;
            rgbaBytes[rgbaIndex + 3] = 255;
            continue;
          }

          final int uvIndex =
              uvPixelStride * (srcX ~/ 2) + uvRowStride * (srcY ~/ 2);
          final int yIndex = srcY * srcWidth + srcX;
          final int rgbaIndex = (y * width + x) * 4;

          if (yIndex >= yPlane.length ||
              uvIndex >= uPlane.length ||
              uvIndex >= vPlane.length ||
              yIndex < 0 ||
              uvIndex < 0) {
            // Fill with black if out of bounds
            rgbaBytes[rgbaIndex] = 0;
            rgbaBytes[rgbaIndex + 1] = 0;
            rgbaBytes[rgbaIndex + 2] = 0;
            rgbaBytes[rgbaIndex + 3] = 255;
            continue;
          }

          final int yp = yPlane[yIndex];
          final int up = uPlane[uvIndex];
          final int vp = vPlane[uvIndex];

          int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255).toInt();
          int g =
              (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
                  .round()
                  .clamp(0, 255)
                  .toInt();
          int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255).toInt();

          rgbaBytes[rgbaIndex] = r;
          rgbaBytes[rgbaIndex + 1] = g;
          rgbaBytes[rgbaIndex + 2] = b;
          rgbaBytes[rgbaIndex + 3] = 255; // Alpha
        }
      }

      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        rgbaBytes,
      );
      final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );

      final ui.Codec codec = await descriptor.instantiateCodec();
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      return frameInfo.image;
    } catch (e) {
      print('Error in _yuv420ToUIImage: $e');
      return null;
    }
  }

  // Helper methods for rotation logic
  int _getRotationAngle(DeviceOrientation orientation) {
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return 90; // Rotate 90 degrees clockwise
      case DeviceOrientation.portraitDown:
        return 270; // Rotate 270 degrees clockwise
      case DeviceOrientation.landscapeLeft:
        return 0; // No rotation needed
      case DeviceOrientation.landscapeRight:
        return 180; // Rotate 180 degrees
    }
  }

  bool _needsRotation(int angle) {
    return angle == 90 || angle == 270;
  }

  // Updated rotation coordinates method
  List<int> _rotateCoordinates(
    int x,
    int y,
    int angle,
    int width,
    int height,
    int srcWidth,
    int srcHeight,
  ) {
    switch (angle) {
      case 0: // No rotation
        return [x, y];
      case 90: // 90 degrees clockwise
        return [y, srcWidth - x - 1];
      case 180: // 180 degrees
        return [srcWidth - x - 1, srcHeight - y - 1];
      case 270: // 270 degrees clockwise (90 counter-clockwise)
        return [srcHeight - y - 1, x];
      default:
        return [x, y];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Gallery (${widget.images.length} images)'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _showExitDialog,
        ),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body:
          widget.images.isEmpty
              ? const Center(
                child: Text(
                  'No images to display',
                  style: TextStyle(color: Colors.white),
                ),
              )
              : GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                  childAspectRatio: 1,
                ),
                itemCount: widget.images.length,
                itemBuilder: (context, index) {
                  // Lazy load more images as user scrolls
                  if (index >=
                      _displayImages.length + _currentlyConverting.length) {
                    _convertImageBatch(index, _batchSize);
                  }

                  final displayImage = _displayImages[index];
                  final isConverting = _currentlyConverting.contains(index);

                  return GestureDetector(
                    onTap:
                        displayImage != null
                            ? () => _showFullscreenImage(
                              context,
                              widget.images[index],
                              index,
                            )
                            : null,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.grey[900],
                      ),
                      child:
                          displayImage != null
                              ? ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: RawImage(
                                  image: displayImage,
                                  fit: BoxFit.cover,
                                ),
                              )
                              : Center(
                                child:
                                    isConverting
                                        ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Colors.white,
                                                ),
                                          ),
                                        )
                                        : const Icon(
                                          Icons.image,
                                          color: Colors.white54,
                                          size: 30,
                                        ),
                              ),
                    ),
                  );
                },
              ),
    );
  }

  void _showExitDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Warning'),
          content: const Text(
            'Unsaved images will be lost. Are you sure you want to return to camera?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Stay'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onBack();
              },
              child: const Text('Return to camera'),
            ),
          ],
        );
      },
    );
  }

  void _showFullscreenImage(
    BuildContext context,
    ImageWithMetadata timestampedImage,
    int index,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => FullscreenImagePage(
              timestampedImage: timestampedImage,
              imageIndex: index,
            ),
      ),
    );
  }

  @override
  void dispose() {
    // Clean up ui.Image objects
    for (final image in _displayImages.values) {
      image.dispose();
    }
    super.dispose();
  }
}

class FullscreenImagePage extends StatelessWidget {
  final ImageWithMetadata timestampedImage;
  final int imageIndex;

  const FullscreenImagePage({
    super.key,
    required this.timestampedImage,
    required this.imageIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () => _saveImage(context),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          child: FutureBuilder<ui.Image?>(
            future: _convertCameraImageToUIImage(
              timestampedImage.image,
              timestampedImage.orientation,
            ),
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data != null) {
                return RawImage(image: snapshot.data!, fit: BoxFit.contain);
              } else if (snapshot.hasError) {
                return const Text(
                  'Error loading image',
                  style: TextStyle(color: Colors.white),
                );
              } else {
                return const CircularProgressIndicator();
              }
            },
          ),
        ),
      ),
    );
  }

  Future<ui.Image?> _convertCameraImageToUIImage(
    CameraImage cameraImage,
    DeviceOrientation orientation,
  ) async {
    try {
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        return await _yuv420ToUIImage(cameraImage, orientation);
      } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        return await _bgraToUIImage(cameraImage, orientation);
      }
      return null;
    } catch (e) {
      print('Error converting image for fullscreen: $e');
      return null;
    }
  }

  Future<ui.Image?> _yuv420ToUIImage(
    CameraImage cameraImage,
    DeviceOrientation orientation,
  ) async {
    // Determine if we need to rotate the image
    bool shouldRotate =
        orientation == DeviceOrientation.portraitUp ||
        orientation == DeviceOrientation.portraitDown;

    // If rotating, swap width and height
    final int width = shouldRotate ? cameraImage.height : cameraImage.width;
    final int height = shouldRotate ? cameraImage.width : cameraImage.height;
    final int srcWidth = cameraImage.width;
    final int srcHeight = cameraImage.height;

    final rgbaBytes = Uint8List(width * height * 4);

    try {
      final int uvRowStride = cameraImage.planes[1].bytesPerRow;
      final int uvPixelStride = cameraImage.planes[1].bytesPerPixel!;

      final yPlane = cameraImage.planes[0].bytes;
      final uPlane = cameraImage.planes[1].bytes;
      final vPlane = cameraImage.planes[2].bytes;

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          // Calculate source coordinates based on rotation
          int srcX, srcY;

          if (shouldRotate) {
            // Rotate 90 degrees clockwise
            srcX = y;
            srcY = srcWidth - x - 1;
          } else {
            srcX = x;
            srcY = y;
          }

          final int uvIndex =
              uvPixelStride * (srcX / 2).floor() +
              uvRowStride * (srcY / 2).floor();
          final int yIndex = srcY * srcWidth + srcX;
          final int rgbaIndex = (y * width + x) * 4;

          if (yIndex >= yPlane.length ||
              uvIndex >= uPlane.length ||
              uvIndex >= vPlane.length) {
            rgbaBytes[rgbaIndex] = 0;
            rgbaBytes[rgbaIndex + 1] = 0;
            rgbaBytes[rgbaIndex + 2] = 0;
            rgbaBytes[rgbaIndex + 3] = 255;
            continue;
          }

          final yp = yPlane[yIndex];
          final up = uPlane[uvIndex];
          final vp = vPlane[uvIndex];

          int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
              .round()
              .clamp(0, 255);
          int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

          rgbaBytes[rgbaIndex] = r;
          rgbaBytes[rgbaIndex + 1] = g;
          rgbaBytes[rgbaIndex + 2] = b;
          rgbaBytes[rgbaIndex + 3] = 255;
        }
      }

      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        rgbaBytes,
      );
      final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );

      final ui.Codec codec = await descriptor.instantiateCodec();
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      return frameInfo.image;
    } catch (e) {
      print('Error in _yuv420ToUIImage: $e');
      return null;
    }
  }

  Future<ui.Image?> _bgraToUIImage(
    CameraImage cameraImage,
    DeviceOrientation orientation,
  ) async {
    try {
      // Determine if we need to rotate the image
      bool shouldRotate =
          orientation == DeviceOrientation.portraitUp ||
          orientation == DeviceOrientation.portraitDown;

      final plane = cameraImage.planes[0];
      final bytes = plane.bytes;
      final int srcWidth = cameraImage.width;
      final int srcHeight = cameraImage.height;

      // If rotating, swap width and height
      final int width = shouldRotate ? srcHeight : srcWidth;
      final int height = shouldRotate ? srcWidth : srcHeight;

      // BGRA is already in the right format, just need to convert to RGBA and possibly rotate
      final rgbaBytes = Uint8List(width * height * 4);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          // Calculate source coordinates based on rotation
          int srcX, srcY;

          if (shouldRotate) {
            // Rotate 90 degrees clockwise
            srcX = y;
            srcY = srcWidth - x - 1;
          } else {
            srcX = x;
            srcY = y;
          }

          final int srcIndex = (srcY * srcWidth + srcX) * 4;
          final int destIndex = (y * width + x) * 4;

          if (srcIndex + 3 < bytes.length) {
            rgbaBytes[destIndex] = bytes[srcIndex + 2]; // R
            rgbaBytes[destIndex + 1] = bytes[srcIndex + 1]; // G
            rgbaBytes[destIndex + 2] = bytes[srcIndex]; // B
            rgbaBytes[destIndex + 3] = bytes[srcIndex + 3]; // A
          } else {
            // Fill with black if out of bounds
            rgbaBytes[destIndex] = 0;
            rgbaBytes[destIndex + 1] = 0;
            rgbaBytes[destIndex + 2] = 0;
            rgbaBytes[destIndex + 3] = 255;
          }
        }
      }

      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        rgbaBytes,
      );
      final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );

      final ui.Codec codec = await descriptor.instantiateCodec();
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      return frameInfo.image;
    } catch (e) {
      print('Error in _bgraToUIImage: $e');
      return null;
    }
  }

  Future<void> _saveImage(BuildContext context) async {
    try {
      final permission = await Permission.storage.request();

      if (permission.isGranted || permission.isLimited) {
        final img_lib.Image? image = _convertCameraImageToImgLib(
          timestampedImage.image,
          timestampedImage.orientation,
        );
        if (image != null) {
          final bytes = Uint8List.fromList(
            img_lib.encodeJpg(image, quality: 95),
          );

          await Gal.putImageBytes(
            bytes,
            name: 'camera_image_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Image saved to gallery successfully!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Storage permission is required to save images'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  img_lib.Image? _convertCameraImageToImgLib(
    CameraImage cameraImage,
    DeviceOrientation orientation,
  ) {
    // Determine if we need to rotate the image
    bool shouldRotate =
        orientation == DeviceOrientation.portraitUp ||
        orientation == DeviceOrientation.portraitDown;

    if (cameraImage.format.group == ImageFormatGroup.yuv420) {
      final int srcWidth = cameraImage.width;
      final int srcHeight = cameraImage.height;

      // If rotating, swap width and height
      final int width = shouldRotate ? srcHeight : srcWidth;
      final int height = shouldRotate ? srcWidth : srcHeight;

      final int uvRowStride = cameraImage.planes[1].bytesPerRow;
      final int uvPixelStride = cameraImage.planes[1].bytesPerPixel!;

      final yPlane = cameraImage.planes[0].bytes;
      final uPlane = cameraImage.planes[1].bytes;
      final vPlane = cameraImage.planes[2].bytes;

      img_lib.Image image = img_lib.Image(width: width, height: height);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          // Calculate source coordinates based on rotation
          int srcX, srcY;

          if (shouldRotate) {
            // Rotate 90 degrees clockwise
            srcX = y;
            srcY = srcWidth - x - 1;
          } else {
            srcX = x;
            srcY = y;
          }

          final int uvIndex =
              uvPixelStride * (srcX / 2).floor() +
              uvRowStride * (srcY / 2).floor();
          final int yIndex = srcY * srcWidth + srcX;

          if (yIndex >= yPlane.length ||
              uvIndex >= uPlane.length ||
              uvIndex >= vPlane.length) {
            image.setPixelRgb(x, y, 0, 0, 0);
            continue;
          }

          final yp = yPlane[yIndex];
          final up = uPlane[uvIndex];
          final vp = vPlane[uvIndex];

          int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
              .round()
              .clamp(0, 255);
          int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

          image.setPixelRgb(x, y, r, g, b);
        }
      }
      return image;
    } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
      final plane = cameraImage.planes[0];
      final bytes = plane.bytes;
      final int srcWidth = cameraImage.width;
      final int srcHeight = cameraImage.height;

      // If rotating, swap width and height
      final int width = shouldRotate ? srcHeight : srcWidth;
      final int height = shouldRotate ? srcWidth : srcHeight;

      img_lib.Image image = img_lib.Image(width: width, height: height);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          // Calculate source coordinates based on rotation
          int srcX, srcY;

          if (shouldRotate) {
            // Rotate 90 degrees clockwise
            srcX = y;
            srcY = srcWidth - x - 1;
          } else {
            srcX = x;
            srcY = y;
          }

          final int srcIndex = (srcY * srcWidth + srcX) * 4;

          if (srcIndex + 3 < bytes.length) {
            final b = bytes[srcIndex];
            final g = bytes[srcIndex + 1];
            final r = bytes[srcIndex + 2];
            image.setPixelRgb(x, y, r, g, b);
          } else {
            image.setPixelRgb(x, y, 0, 0, 0);
          }
        }
      }
      return image;
    }
    return null;
  }
}
