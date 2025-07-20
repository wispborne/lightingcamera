import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/gallery_page.dart';
import 'package:lightingcamera/camera/image_cache_manager.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => CameraPageState();
}

class CameraPageState extends State<CameraPage> with RouteAware {
  CameraController? controller;
  Future<void>? _initializeControllerFuture;
  List<CameraDescription>? _cameras;
  bool isRecording = false;
  bool _isPageVisible = true;

  final ImageCacheManager _cacheManager = ImageCacheManager();

  img_lib.Image? displayImage;
  int _imagesCapturedLastSecond = 0;
  int _fps = 0;
  bool showLivePreview = false;

  static final RouteObserver<PageRoute> routeObserver =
      RouteObserver<PageRoute>();

  @override
  void initState() {
    super.initState();
    _initializeControllerFuture = _initializeCamera();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    controller?.dispose();
    super.dispose();
  }

  // RouteAware methods
  @override
  void didPush() {
    // Route was pushed onto navigator and is now topmost route
    _isPageVisible = true;
    if (!isRecording && controller != null && controller!.value.isInitialized) {
      _startRecording();
    }
  }

  @override
  void didPopNext() {
    // Covering route was popped off the navigator, this route is now topmost
    _isPageVisible = true;
    if (!isRecording && controller != null && controller!.value.isInitialized) {
      _startRecording();
    }
  }

  @override
  void didPushNext() {
    // Route was pushed on top of this route
    _isPageVisible = false;
    if (isRecording) {
      _stopRecording();
    }
  }

  @override
  void didPop() {
    // Route was popped off the navigator
    _isPageVisible = false;
    if (isRecording) {
      _stopRecording();
    }
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

    // Find the main back camera from the list of available cameras.
    CameraDescription? backCamera;
    for (final camera in _cameras!) {
      if (camera.lensDirection == CameraLensDirection.back) {
        backCamera = camera;
        break;
      }
    }

    // If no back camera is found, fall back to the first available camera
    final selectedCamera = backCamera ?? _cameras![0];

    controller = CameraController(selectedCamera, ResolutionPreset.high);

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

    // Start recording immediately after initialization if page is visible
    if (_isPageVisible) {
      _startRecording();
    }
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
                            style: const TextStyle(color: Colors.white),
                          ),
                          if (!_isPageVisible || !isRecording)
                            const Text(
                              'Recording paused',
                              style: TextStyle(color: Colors.orange),
                            ),
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
                        const Spacer(),
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
              images: _cacheManager.getTimestampedImages(),
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

    try {
      await controller!.startImageStream((CameraImage image) async {
        if (!mounted) return;

        // Get the actual device orientation
        DeviceOrientation orientation = await _getDeviceOrientation();

        _cacheManager.addImage(
          image,
          orientation,
          controller!.description.lensDirection,
        );
        _imagesCapturedLastSecond++;

        if (mounted) {
          setState(() {}); // Update UI with new cache size
        }
      });
      setState(() {
        isRecording = true;
      });
    } catch (e) {
      print('Error starting recording: $e');
    }
  }

  Future<DeviceOrientation> _getDeviceOrientation() async {
    // Get the current system orientation
    final List<DeviceOrientation> orientations = await SystemChannels.platform
        .invokeMethod<List<dynamic>>('SystemChrome.getSystemUIOverlayStyle')
        .then((dynamic result) => <DeviceOrientation>[]);

    // Fallback to using MediaQuery with better mapping
    switch (MediaQuery.orientationOf(context)) {
      case Orientation.portrait:
        // You might want to use device sensors here for more accurate detection
        return DeviceOrientation.portraitUp;
      case Orientation.landscape:
        return DeviceOrientation.landscapeLeft;
    }
  }

  void _stopRecording() async {
    if (controller == null || !controller!.value.isInitialized || !isRecording)
      return;

    try {
      await controller!.pausePreview();
      await controller!.pauseVideoRecording();
      await controller!.stopImageStream();
      setState(() {
        isRecording = false;
      });
    } catch (e) {
      print('Error stopping recording: $e');
    }
  }
}
