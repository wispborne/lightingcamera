import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/gallery_page.dart';
import 'package:lightingcamera/camera/image_cache_manager.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? controller;
  Future<void>? _initializeControllerFuture;
  List<CameraDescription>? _cameras;
  bool isRecording = false;

  final ImageCacheManager _cacheManager = ImageCacheManager();

  img_lib.Image? displayImage;
  bool _isConverting = false;
  CameraImage? _latestImageToConvert;
  int _imagesCapturedLastSecond = 0;
  int _fps = 0;
  bool showLivePreview = false;

  @override
  void initState() {
    super.initState();
    _initializeControllerFuture = _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    // Start a timer to calculate FPS
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false; // Stop if the widget is disposed
      _fps = _imagesCapturedLastSecond;
      _imagesCapturedLastSecond = 0;
      setState(() {}); // Update the UI with the new FPS
      return true; // Continue the loop
    });
    // Obtain a list of the available cameras on the device.
    _cameras = await availableCameras();

    // Get a specific camera from the list of available cameras.
    controller = CameraController(_cameras![0], ResolutionPreset.high);

    try {
      await controller?.initialize();
    } on CameraException catch (e) {
      switch (e.code) {
        case 'CameraAccessDenied':
          // Handle access errors here.
          break;
        default:
          // Handle other errors here.
          break;
      }
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {});

    // Start recording immediately after initialization
    _startRecording();
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (controller != null && _cameras != null) {
          return Stack(
            children: [
              CameraPreview(controller!),
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Caching the last ${_cacheManager.getCacheDurationSeconds().toStringAsFixed(1)} seconds',
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Image Count: ${_cacheManager.cacheSize} | FPS: $_fps | Cache: ${_cacheManager.getCacheMemoryUsageMB().toStringAsFixed(1)}MB',
                          ),
                          // IconButton(
                          //   onPressed: () {
                          //     setState(() {
                          //       showLivePreview = !showLivePreview;
                          //     });
                          //   },
                          //   icon: Icon(
                          //     showLivePreview
                          //         ? Icons.image_not_supported
                          //         : Icons.image,
                          //     color: Colors.white,
                          //   ),
                          // ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Camera shutter button section
                  Padding(
                    padding: const EdgeInsets.only(bottom: 50),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        const Spacer(),
                        // Shutter button
                        GestureDetector(
                          onTap: _onShutterPressed,
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(color: Colors.grey, width: 3),
                            ),
                            child: Container(
                              margin: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        Spacer(),
                        // Live preview thumbnail
                        // Container(
                        //   width: 80,
                        //   height: 80,
                        //   decoration: BoxDecoration(
                        //     borderRadius: BorderRadius.circular(8),
                        //     border: Border.all(
                        //       color: Colors.white,
                        //       width: 2,
                        //     ),
                        //   ),
                        //   child: ClipRRect(
                        //     borderRadius: BorderRadius.circular(6),
                        //     child: displayImage != null
                        //         ? Image.memory(
                        //             Uint8List.fromList(
                        //               img_lib.encodePng(displayImage!),
                        //             ),
                        //             gaplessPlayback: true,
                        //             fit: BoxFit.cover,
                        //           )
                        //         : _cacheManager.cacheSize > 0
                        //             ? const Center(
                        //                 child: Icon(
                        //                   Icons.image,
                        //                   color: Colors.white,
                        //                   size: 30,
                        //                 ),
                        //               )
                        //             : const Center(
                        //                 child: Icon(
                        //                   Icons.camera_alt,
                        //                   color: Colors.white,
                        //                   size: 30,
                        //                 ),
                        //               ),
                        //   ),
                        // ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        } else {
          // Otherwise, display a loading indicator.
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }

  void _onShutterPressed() {
    if (_cacheManager.cacheSize > 0) {
      _openGallery();
    }
  }

  void _openGallery() {
    if (_cacheManager.cacheSize == 0) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (context) => GalleryPage(
              images: _cacheManager.getCachedImages(),
              onBack: () {
                // Clear cache when returning from gallery
                _cacheManager.clearCache();
                Navigator.of(context).pop();
                setState(() {}); // Refresh UI to show updated cache size
              },
            ),
      ),
    );
  }

  void _startRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;

    await controller!.startImageStream((CameraImage image) async {
      if (!mounted) return;

      // Add image to cache manager
      _cacheManager.addImage(image);
      _imagesCapturedLastSecond++;

      if (mounted) {
        setState(() {}); // Update UI with new cache size
      }

      // Store the latest image for potential conversion
      _latestImageToConvert = image;

      // This cuts FPS on PC from 20 fps to 14.
      // If not currently converting, start a new conversion for the latest image
      if (showLivePreview && !_isConverting) {
        _isConverting = true;
        // Use the latest image available at the time of starting conversion
        CameraImage? imageToProcess = _latestImageToConvert;
        _latestImageToConvert =
            null; // Clear it so we don't process it again if another comes in fast

        if (imageToProcess != null) {
          // Perform conversion
          // img_lib.Image? convertedImage = _convertCameraImage(imageToProcess);
          //
          // if (!mounted) return;
          // setState(() {
          //   if (convertedImage != null) {
          //     displayImage = convertedImage;
          //   }
          // });
        }
        _isConverting = false; // Ready for next conversion
      }
    });
    setState(() {
      isRecording = true;
    });
  }

  void _stopRecording() async {
    await controller!.stopImageStream();
    setState(() {
      isRecording = false;
    });
  }

  // Helper function to convert CameraImage to image_lib.Image
  // This is a simplified example and might need adjustments based on the image format
  img_lib.Image? _convertCameraImage(CameraImage cameraImage) {
    if (cameraImage.format.group == ImageFormatGroup.yuv420) {
      // YUV420 conversion (common format)
      // This is a basic YUV420 to RGB conversion.
      // For more accurate and optimized conversion, especially for different YUV types,
      // refer to the 'image' package documentation or more specialized image processing libraries.
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
        // Adjust if needed
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
