import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/image_cache_manager.dart';
import 'package:lightingcamera/main.dart';
import 'package:native_device_orientation/native_device_orientation.dart';

class CameraPage extends ConsumerStatefulWidget {
  const CameraPage({super.key});

  @override
  ConsumerState<CameraPage> createState() => CameraPageState();
}

class CameraPageState extends ConsumerState<CameraPage> with RouteAware {
  CameraController? controller;
  Future<void>? _initializeControllerFuture;
  List<CameraDescription>? _cameras;
  bool isRecording = false;
  bool _isPageVisible = true;

  img_lib.Image? displayImage;
  int _imagesCapturedLastSecond = 0;
  int _fps = 0;
  bool showLivePreview = false;
  DeviceOrientation _currentOrientation = DeviceOrientation.portraitUp;

  // Exposure compensation variables
  double _exposureCompensation = 0.0;
  double _sliderExposureValue = 0.0; // Add separate slider value
  double _minExposureCompensation = -2.0;
  double _maxExposureCompensation = 2.0;

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
    if (controller != null && controller!.value.isInitialized) {
      controller!.resumePreview();
    }

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

      // Get exposure compensation limits after initialization
      if (controller != null && controller!.value.isInitialized) {
        _minExposureCompensation = await controller!.getMinExposureOffset();
        _maxExposureCompensation = await controller!.getMaxExposureOffset();
      }
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

  Future<void> _setExposureCompensation(double value) async {
    if (controller == null || !controller!.value.isInitialized) {
      return;
    }

    try {
      await controller!.setExposureOffset(value);
      setState(() {
        _exposureCompensation = value;
        _sliderExposureValue = value; // Update slider value
      });
      print('Set exposure compensation to: $value');
    } catch (e) {
      // Don't update if setting failed, but update slider to reflect actual value
      setState(() {
        _sliderExposureValue =
            _exposureCompensation; // Reset slider to last known good value
      });
      print('Error setting exposure compensation: $e');
    }
  }

  Widget _buildVerticalExposureSlider() {
    return Container(
      height: 180,
      width: 50,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(25),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Exposure icon
          const Icon(Icons.wb_sunny_outlined, color: Colors.white, size: 16),
          const SizedBox(height: 4),

          // Current value display
          Text(
            _sliderExposureValue.toStringAsFixed(1), // Show slider value
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),

          // Vertical slider
          Expanded(
            child: RotatedBox(
              quarterTurns: -1, // Rotate 90 degrees counter-clockwise
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white38,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withOpacity(0.2),
                  trackHeight: 2.0,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  value: _sliderExposureValue,
                  // Use separate slider value
                  min: _minExposureCompensation,
                  max: _maxExposureCompensation,
                  divisions:
                      ((_maxExposureCompensation - _minExposureCompensation) *
                              10)
                          .round(),
                  onChanged: (value) {
                    setState(() {
                      _sliderExposureValue = value; // Update slider immediately
                    });
                    _setExposureCompensation(value); // Then try to set camera
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),

          // Reset button
          GestureDetector(
            onTap: () {
              setState(() {
                _sliderExposureValue = 0.0; // Reset slider immediately
              });
              _setExposureCompensation(0.0); // Then reset camera
            },
            child: Container(
              width: 24,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text(
                  '0',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cacheManager = ref.read(imageCacheProvider);

    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (controller != null && _cameras != null) {
          return Stack(
            children: [
              NativeDeviceOrientationReader(
                builder: (context) {
                  _currentOrientation = NativeDeviceOrientationReader.orientation(context).deviceOrientation ?? DeviceOrientation.portraitUp;

                  return CameraPreview(controller!);
                }
              ),
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
                            'Caching the last ${cacheManager.getCacheDurationSeconds().toStringAsFixed(1)} seconds',
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Image Count: ${cacheManager.cacheSize} | FPS: $_fps | Cache: ${cacheManager.getCacheMemoryUsageMB().toStringAsFixed(1)}MB',
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

              // Vertical exposure slider in bottom-right corner
              Positioned(
                bottom: 140, // Above the shutter button
                right: 16,
                child: _buildVerticalExposureSlider(),
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
    final cacheManager = ref.read(imageCacheProvider);
    if (cacheManager.cacheSize > 0) {
      _openGallery();
    }
  }

  void _openGallery() {
    final cacheManager = ref.read(imageCacheProvider);
    if (cacheManager.cacheSize == 0) return;

    context.goNamed(Pages.gallery);
  }

  void _startRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;
    final cacheManager = ref.read(imageCacheProvider);

    try {
      await controller!.startImageStream((CameraImage image) async {
        if (!mounted) return;

        // Get the actual device orientation
        DeviceOrientation orientation = _currentOrientation;

        cacheManager.addImage(
          image,
          orientation,
          controller!.description.lensDirection,
        );
        _imagesCapturedLastSecond++;
      });
      setState(() {
        isRecording = true;
      });
    } catch (e) {
      print('Error starting recording: $e');
    }
  }

  // Future<DeviceOrientation> _getDeviceOrientation() async {
  //   if (!context.mounted) {
  //     return DeviceOrientation.portraitUp;
  //   }
  //
  //   return (await NativeDeviceOrientationCommunicator().orientation(
  //         useSensor: true,
  //       )).deviceOrientation ??
  //       DeviceOrientation.portraitUp;
  //
  //   switch (MediaQuery.orientationOf(context)) {
  //     case Orientation.portrait:
  //       // You might want to use device sensors here for more accurate detection
  //       return DeviceOrientation.portraitUp;
  //     case Orientation.landscape:
  //       return DeviceOrientation.landscapeLeft;
  //   }
  // }

  void _stopRecording() async {
    if (controller == null ||
        !controller!.value.isInitialized ||
        !isRecording) {
      return;
    }

    try {
      await controller!.pausePreview();
      await controller!.stopImageStream();
      setState(() {
        isRecording = false;
      });
    } catch (e) {
      print('Error stopping recording: $e');
    }
  }
}
