import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/image_cache_manager.dart';
import 'package:lightingcamera/main.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:volume_controller/volume_controller.dart';

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

  img_lib.Image? displayImage;
  int _imagesCapturedLastSecond = 0;
  int _fps = 0;
  bool showLivePreview = false;
  DeviceOrientation _currentOrientation = DeviceOrientation.portraitUp;

  // Exposure compensation variables
  double _exposureCompensation = 0.0;
  double _sliderExposureValue = 0.0;
  double _minExposureCompensation = -2.0;
  double _maxExposureCompensation = 2.0;

  // Volume button variables
  VolumeController? _volumeController;
  double _originalVolume = 0.0;
  bool _volumeButtonsEnabled = true;
  bool _isVolumeControllerInitialized = false;

  static final RouteObserver<PageRoute> routeObserver =
      RouteObserver<PageRoute>();

  @override
  void initState() {
    super.initState();
    _initializeControllerFuture = _initializeCamera();
    _initializeVolumeController();
  }

  Future<void> _initializeVolumeController() async {
    try {
      _volumeController = VolumeController.instance;

      // Store the original volume level
      _originalVolume = await _volumeController!.getVolume();

      // Hide the system volume UI completely
      _volumeController!.showSystemUI = false;

      // Set up listener that intercepts volume changes
      _volumeController!.addListener((newVolume) {
        if (_volumeButtonsEnabled &&
            _isPageVisible &&
            _isVolumeControllerInitialized) {
          // Immediately restore the original volume to prevent any volume change
          _volumeController!.setVolume(_originalVolume);

          // Trigger the camera shutter
          _onShutterPressed();
        }
      });

      _isVolumeControllerInitialized = true;
    } catch (e) {
      print('Error initializing volume controller: $e');
    }
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
    _volumeController?.removeListener();
    // Restore system volume UI when leaving
    _volumeController?.showSystemUI = true;
    controller?.dispose();
    super.dispose();
  }

  // RouteAware methods
  @override
  void didPush() {
    _isPageVisible = true;
    _volumeButtonsEnabled = true;
    _enableVolumeButtonOverride();
    if (!isRecording && controller != null && controller!.value.isInitialized) {
      _startRecording();
    }
  }

  @override
  void didPopNext() {
    _isPageVisible = true;
    _volumeButtonsEnabled = true;
    _enableVolumeButtonOverride();
    if (controller != null && controller!.value.isInitialized) {
      controller!.resumePreview();
    }

    if (!isRecording && controller != null && controller!.value.isInitialized) {
      _startRecording();
    }
  }

  @override
  void didPushNext() {
    _isPageVisible = false;
    _volumeButtonsEnabled = false;
    _disableVolumeButtonOverride();
    if (isRecording) {
      _stopRecording();
    }
  }

  @override
  void didPop() {
    _isPageVisible = false;
    _volumeButtonsEnabled = false;
    _disableVolumeButtonOverride();
    if (isRecording) {
      _stopRecording();
    }
  }

  void _enableVolumeButtonOverride() async {
    if (_volumeController != null) {
      // Store current volume when enabling override
      _originalVolume = await _volumeController!.getVolume();
      _volumeController!.showSystemUI = false;
    }
  }

  void _disableVolumeButtonOverride() async {
    if (_volumeController != null) {
      // Re-enable system volume UI when disabling override
      _volumeController!.showSystemUI = true;
    }
  }

  Future<void> _initializeCamera() async {
    // Start a timer to calculate FPS
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      _fps = _imagesCapturedLastSecond;
      _imagesCapturedLastSecond = 0;
      setState(() {});
      return true;
    });

    _cameras = await availableCameras();

    CameraDescription? backCamera;
    for (final camera in _cameras!) {
      if (camera.lensDirection == CameraLensDirection.back) {
        backCamera = camera;
        break;
      }
    }

    final selectedCamera = backCamera ?? _cameras![0];
    controller = CameraController(selectedCamera, ResolutionPreset.high);

    try {
      await controller?.initialize();

      if (controller != null && controller!.value.isInitialized) {
        _minExposureCompensation = await controller!.getMinExposureOffset();
        _maxExposureCompensation = await controller!.getMaxExposureOffset();
      }
    } on CameraException catch (e) {
      switch (e.code) {
        case 'CameraAccessDenied':
          break;
        default:
          break;
      }
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {});

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
        _sliderExposureValue = value;
      });
      print('Set exposure compensation to: $value');
    } catch (e) {
      setState(() {
        _sliderExposureValue = _exposureCompensation;
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
          const Icon(Icons.wb_sunny_outlined, color: Colors.white, size: 16),
          const SizedBox(height: 4),
          Text(
            _sliderExposureValue.toStringAsFixed(1),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
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
                  min: _minExposureCompensation,
                  max: _maxExposureCompensation,
                  divisions:
                      ((_maxExposureCompensation - _minExposureCompensation) *
                              10)
                          .round(),
                  onChanged: (value) {
                    setState(() {
                      _sliderExposureValue = value;
                    });
                    _setExposureCompensation(value);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () {
              setState(() {
                _sliderExposureValue = 0.0;
              });
              _setExposureCompensation(0.0);
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
    final cacheManager = imageCacheManager;

    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (controller != null && _cameras != null) {
          return Stack(
            children: [
              NativeDeviceOrientationReader(
                builder: (context) {
                  _currentOrientation =
                      NativeDeviceOrientationReader.orientation(
                        context,
                      ).deviceOrientation ??
                      DeviceOrientation.portraitUp;
                  return CameraPreview(controller!);
                },
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
                            'Image Count: ${cacheManager.cacheSize.value} | FPS: $_fps | Cache: ${cacheManager.getCacheMemoryUsageMB().toStringAsFixed(1)}MB',
                            style: const TextStyle(color: Colors.white),
                          ),
                          Row(
                            children: [
                              Icon(
                                Icons.volume_up,
                                color:
                                    _volumeButtonsEnabled
                                        ? Colors.green
                                        : Colors.orange,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Volume shutter: ${_volumeButtonsEnabled ? "Active" : "Inactive"}',
                                style: TextStyle(
                                  color:
                                      _volumeButtonsEnabled
                                          ? Colors.green
                                          : Colors.orange,
                                  fontSize: 12,
                                ),
                              ),
                            ],
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
                  Padding(
                    padding: const EdgeInsets.only(bottom: 50),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        const Spacer(),
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
              Positioned(
                bottom: 140,
                right: 16,
                child: _buildVerticalExposureSlider(),
              ),
            ],
          );
        } else {
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }

  void _onShutterPressed() {
    final cacheManager = imageCacheManager;
    if (cacheManager.cacheSize.value > 0) {
      _openGallery();
    }
  }

  void _openGallery() {
    final cacheManager = imageCacheManager;
    if (cacheManager.cacheSize.value == 0) return;
    context.goNamed(Pages.gallery);
  }

  void _startRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;
    final cacheManager = imageCacheManager;

    try {
      await controller!.startImageStream((CameraImage image) async {
        if (!mounted) return;

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
