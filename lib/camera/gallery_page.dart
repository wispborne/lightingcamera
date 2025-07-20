import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/image_converter.dart';
import 'package:lightingcamera/main.dart';
import 'package:permission_handler/permission_handler.dart';

import 'image_cache_manager.dart';

class GalleryPage extends ConsumerStatefulWidget {
  const GalleryPage({super.key});

  @override
  ConsumerState<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends ConsumerState<GalleryPage> {
  List<ImageWithMetadata> images = [];
  final Map<int, ProcessedImage> _displayImages = {};
  final Set<int> _currentlyConverting = {};
  final int _batchSize = 3;

  @override
  void initState() {
    super.initState();
    images = ref.read(imageCacheProvider).getTimestampedImages();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _convertImageBatch(0, _batchSize);
    });
  }

  Future<void> _convertImageBatch(int start, int count) async {
    final end = (start + count).clamp(0, images.length);

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
      final timestampedImage = images[index];
      final displayImage = await _convertCameraImageToUIImage(timestampedImage);

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

  Future<ProcessedImage?> _convertCameraImageToUIImage(
    ImageWithMetadata cameraImage,
  ) async {
    try {
      if (cameraImage.image.format.group == ImageFormatGroup.yuv420) {
        return ImageConverter.processImage(cameraImage);
      }
      return null;
    } catch (e) {
      print('Error in _convertCameraImageToUIImage: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent automatic popping
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          _showExitDialog();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Gallery (${images.length} images)'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _showExitDialog,
          ),
          backgroundColor: Colors.black87,
          foregroundColor: Colors.white,
        ),
        backgroundColor: Colors.black,
        body:
            images.isEmpty
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
                  itemCount: images.length,
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
                                _displayImages[index]!,
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
                                  child: FutureBuilder(
                                    future: displayImage.displayableBytes,
                                    builder:
                                        (context, asyncSnapshot) =>
                                            !asyncSnapshot.hasData
                                                ? const Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                )
                                                : Image.memory(
                                                  asyncSnapshot.requireData,
                                                ),
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
                                              color: Colors.white,
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
                final cacheManager = ref.read(imageCacheProvider);
                cacheManager.clearCache();
                context.goNamed(Pages.home);
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
    ProcessedImage timestampedImage,
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
    // for (final image in _displayImages.values) {
    //   image.dispose();
    // }
    super.dispose();
  }
}

class FullscreenImagePage extends StatelessWidget {
  final ProcessedImage timestampedImage;
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
          child: FutureBuilder(
            future: timestampedImage.displayableBytes,
            builder:
                (context, asyncSnapshot) =>
                    !asyncSnapshot.hasData
                        ? const Center(child: CircularProgressIndicator())
                        : Image.memory(asyncSnapshot.requireData),
          ),
        ),
      ),
    );
  }

  Future<void> _saveImage(BuildContext context) async {
    try {
      // Check current permission status
      PermissionStatus permission = await Permission.photos.status;

      // If permission is not granted, request it
      if (!permission.isGranted) {
        permission = await Permission.photos.request();
      }

      // Handle different permission states
      if (permission.isGranted || permission.isLimited) {
        final img_lib.Image image = timestampedImage.image;
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
      } else if (permission.isPermanentlyDenied) {
        // User has permanently denied permission, show dialog to go to settings
        if (context.mounted) {
          _showPermissionDialog(context);
        }
      } else {
        // Permission denied
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

  void _showPermissionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Storage Permission Required'),
          content: const Text(
            'This app needs storage permission to save images to your gallery. Please enable it in the app settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }
}
