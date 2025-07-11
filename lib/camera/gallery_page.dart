import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img_lib;
import 'package:permission_handler/permission_handler.dart';

class GalleryPage extends StatefulWidget {
  final List<CameraImage> images;
  final VoidCallback onBack;

  const GalleryPage({super.key, required this.images, required this.onBack});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  final Map<int, img_lib.Image> _convertedImages = {};
  final Set<int> _currentlyConverting = {};
  final int _batchSize = 5; // Convert images in batches to avoid blocking UI

  @override
  void initState() {
    super.initState();
    // Start converting the first batch of images
    _convertImageBatch(0, _batchSize);
  }

  Future<void> _convertImageBatch(int start, int count) async {
    final end = (start + count).clamp(0, widget.images.length);

    for (int i = start; i < end; i++) {
      if (_convertedImages.containsKey(i) || _currentlyConverting.contains(i)) {
        continue;
      }

      _currentlyConverting.add(i);

      // Convert image in background
      _convertSingleImage(i);
    }
  }

  Future<void> _convertSingleImage(int index) async {
    try {
      final cameraImage = widget.images[index];

      // Convert image in a separate isolate to avoid blocking UI
      final convertedImage = await _convertCameraImageAsync(cameraImage);

      if (mounted && convertedImage != null) {
        setState(() {
          _convertedImages[index] = convertedImage;
          _currentlyConverting.remove(index);
        });
      }
    } catch (e) {
      if (mounted) {
        _currentlyConverting.remove(index);
      }
    }
  }

  Future<img_lib.Image?> _convertCameraImageAsync(CameraImage cameraImage) async {
    // For now, we'll do the conversion on the main isolate but with yielding
    // In a production app, you might want to use a separate isolate
    return await Future.microtask(() => _convertCameraImage(cameraImage));
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
      body: widget.images.isEmpty
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
                if (index >= _convertedImages.length + _currentlyConverting.length) {
                  _convertImageBatch(index, _batchSize);
                }

                final convertedImage = _convertedImages[index];
                final isConverting = _currentlyConverting.contains(index);

                return GestureDetector(
                  onTap: convertedImage != null
                      ? () => _showFullscreenImage(context, convertedImage, index)
                      : null,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: Colors.grey[900],
                    ),
                    child: convertedImage != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.memory(
                              Uint8List.fromList(img_lib.encodePng(convertedImage)),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          )
                        : Center(
                            child: isConverting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
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
    img_lib.Image image,
    int index,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => FullscreenImagePage(image: image, imageIndex: index),
      ),
    );
  }

  // Helper function to convert CameraImage to image_lib.Image
  img_lib.Image? _convertCameraImage(CameraImage cameraImage) {
    if (cameraImage.format.group == ImageFormatGroup.yuv420) {
      // YUV420 conversion (common format)
      final int width = cameraImage.width;
      final int height = cameraImage.height;
      final int uvRowStride = cameraImage.planes[1].bytesPerRow;
      final int uvPixelStride = cameraImage.planes[1].bytesPerPixel!;

      final yPlane = cameraImage.planes[0].bytes;
      final uPlane = cameraImage.planes[1].bytes;
      final vPlane = cameraImage.planes[2].bytes;

      img_lib.Image image = img_lib.Image(width: width, height: height);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int uvIndex =
              uvPixelStride * (x / 2).floor() + uvRowStride * (y / 2).floor();
          final int index = y * width + x;

          final yp = yPlane[index];
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
      // BGRA8888 to RGB conversion
      final plane = cameraImage.planes[0];
      return img_lib.Image.fromBytes(
        width: cameraImage.width,
        height: cameraImage.height,
        bytes: plane.bytes.buffer,
        format: img_lib.Format.uint8,
        rowStride: plane.bytesPerRow,
        order: img_lib.ChannelOrder.bgra,
      );
    } else {
      // Handle other formats or return null
      print('Unsupported image format: ${cameraImage.format.group}');
      return null;
    }
  }
}

class FullscreenImagePage extends StatelessWidget {
  final img_lib.Image image;
  final int imageIndex;

  const FullscreenImagePage({
    super.key,
    required this.image,
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
          child: Image.memory(
            Uint8List.fromList(img_lib.encodePng(image)),
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }

  Future<void> _saveImage(
    BuildContext context, {
    String format = "webp",
  }) async {
    try {
      // Request storage permission
      final permission = await Permission.storage.request();

      if (permission.isGranted || permission.isLimited) {
        // Convert image to bytes
        final bytes = Uint8List.fromList(img_lib.encodePng(image));

        // Save to gallery
        try {
          await Gal.putImageBytes(
            bytes,
            // quality: 100,
            name:
                'camera_image_${DateTime.now().millisecondsSinceEpoch}.$format',
          );

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Image saved to gallery successfully!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to save image to gallery'),
                backgroundColor: Colors.red,
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
}
