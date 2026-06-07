import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/image_cache_manager.dart';
import 'package:lightingcamera/main.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => CameraPageState();
}

class CameraPageState extends State<CameraPage>
    with RouteAware, WidgetsBindingObserver, TickerProviderStateMixin {
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

  // Wiggle animation for reposition mode
  late final AnimationController _wiggleController;
  double? _dragOffsetX;

  // Volume button shutter via native platform channel
  static const _volumeKeyChannel =
      MethodChannel('com.wisp.lightingcamera/volume_keys');
  bool _volumeButtonsEnabled = true;
  DateTime? _lastShutterTime;

  static final RouteObserver<PageRoute> routeObserver =
      RouteObserver<PageRoute>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wiggleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _initializeControllerFuture = _initializeCamera();
    _volumeKeyChannel.setMethodCallHandler(_handleVolumeKey);
  }

  Future<dynamic> _handleVolumeKey(MethodCall call) async {
    if (call.method == 'volumeKeyPressed' &&
        _volumeButtonsEnabled &&
        _isPageVisible) {
      final now = DateTime.now();
      if (_lastShutterTime == null ||
          now.difference(_lastShutterTime!) > const Duration(milliseconds: 300)) {
        _lastShutterTime = now;
        _onShutterPressed();
      }
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
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    _wiggleController.dispose();
    _volumeKeyChannel.setMethodCallHandler(null);
    _disposeCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (_isPageVisible) {
        _initializeControllerFuture = _setupCamera();
      }
    }
  }

  // RouteAware methods
  @override
  void didPush() {
    _isPageVisible = true;
    _volumeButtonsEnabled = true;
    if (!isRecording && controller != null && controller!.value.isInitialized) {
      _startRecording();
    }
  }

  @override
  void didPopNext() {
    _isPageVisible = true;
    _volumeButtonsEnabled = true;
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
    if (isRecording) {
      _stopRecording();
    }
  }

  @override
  void didPop() {
    _isPageVisible = false;
    _volumeButtonsEnabled = false;
    if (isRecording) {
      _stopRecording();
    }
  }

  Future<void> _initializeCamera() async {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      _fps = _imagesCapturedLastSecond;
      _imagesCapturedLastSecond = 0;
      setState(() {});
      return true;
    });

    await _setupCamera();
  }

  Future<void> _setupCamera() async {
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
      Fimber.e('Error initializing camera: $e', ex: e);
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

  Future<void> _disposeCamera() async {
    if (isRecording) {
      try {
        await controller?.stopImageStream();
      } catch (e) {
        Fimber.e('Error stopping image stream: $e', ex: e);
      }
      isRecording = false;
      WakelockPlus.disable();
    }
    try {
      await controller?.dispose();
    } catch (e) {
      Fimber.e('Error disposing camera: $e', ex: e);
    }
    controller = null;
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
      Fimber.i('Set exposure compensation to: $value');
    } catch (e) {
      setState(() {
        _sliderExposureValue = _exposureCompensation;
      });
      Fimber.e('Error setting exposure compensation: $e', ex: e);
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
                  return SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller!.value.previewSize!.height,
                        height: controller!.value.previewSize!.width,
                        child: CameraPreview(controller!),
                      ),
                    ),
                  );
                },
              ),
              Positioned(
                top: 0,
                left: 8,
                right: 8,
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
              Watch((context) {
                final offsetX = settingsManager.shutterOffsetXSignal.watch(context);
                final isRepositioning = settingsManager.isRepositioningSignal.watch(context);
                _syncWiggle(isRepositioning);
                final currentOffset = _dragOffsetX ?? offsetX;
                return _buildShutterButton(currentOffset, isRepositioning);
              }),
              Watch((context) {
                final isRepositioning = settingsManager.isRepositioningSignal.watch(context);
                if (!isRepositioning) return const SizedBox.shrink();
                return _buildSaveBar();
              }),
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () => context.pushNamed(Pages.settings),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.settings, color: Colors.white, size: 22),
                  ),
                ),
              ),
              Positioned(
                top: 56,
                right: 8,
                child: GestureDetector(
                  onTap: () => context.pushNamed(Pages.map),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.bolt, color: Colors.white, size: 22),
                  ),
                ),
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

  static const _buttonSize = 80.0;
  static const _buttonPadding = 40.0;
  bool _wiggleActive = false;

  void _syncWiggle(bool isRepositioning) {
    if (isRepositioning && !_wiggleActive) {
      _wiggleActive = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _wiggleController.repeat(reverse: true);
      });
    } else if (!isRepositioning && _wiggleActive) {
      _wiggleActive = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _wiggleController.stop();
          _wiggleController.reset();
        }
      });
    }
  }

  Widget _buildShutterButton(double offsetX, bool isRepositioning) {
    final screenWidth = MediaQuery.of(context).size.width;
    final draggableWidth = screenWidth - _buttonSize - _buttonPadding * 2;
    final left = _buttonPadding + draggableWidth * offsetX.clamp(0.0, 1.0);

    Widget button = Container(
      width: _buttonSize,
      height: _buttonSize,
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
    );

    if (isRepositioning) {
      button = AnimatedBuilder(
        animation: _wiggleController,
        builder: (context, child) {
          final angle = math.sin(_wiggleController.value * 2 * math.pi) * 0.087; // ±5°
          return Transform.rotate(angle: angle, child: child);
        },
        child: button,
      );

      button = GestureDetector(
        onHorizontalDragUpdate: (details) {
          if (draggableWidth <= 0) return;
          final currentOffset = _dragOffsetX ?? settingsManager.shutterOffsetX;
          final delta = details.delta.dx / draggableWidth;
          setState(() {
            _dragOffsetX = (currentOffset + delta).clamp(0.0, 1.0);
          });
        },
        onHorizontalDragEnd: (details) {
          if (_dragOffsetX != null) {
            settingsManager.setShutterOffsetX(_dragOffsetX!);
            _dragOffsetX = null;
          }
        },
        child: button,
      );
    } else {
      button = GestureDetector(
        onTap: _onShutterPressed,
        child: button,
      );
    }

    return Positioned(
      bottom: 50,
      left: left,
      child: button,
    );
  }

  Widget _buildSaveBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: Colors.black.withOpacity(0.7),
        child: SafeArea(
          bottom: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Drag the shutter button to reposition',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () {
                  settingsManager.exitRepositionMode();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
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
    context.pushNamed(Pages.gallery);
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
      WakelockPlus.enable();
    } catch (e) {
      Fimber.e('Error starting recording: $e', ex: e);
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
      WakelockPlus.disable();
    } catch (e) {
      Fimber.e('Error stopping recording: $e', ex: e);
    }
  }
}
