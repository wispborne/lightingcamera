import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/image_cache_manager.dart';
import 'package:lightingcamera/lightning/mini_map.dart';
import 'package:lightingcamera/lightning/mini_map_controller.dart';
import 'package:lightingcamera/lightning/strike_overlay.dart';
import 'package:lightingcamera/lightning/strike_overlay_controller.dart';
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

  // Strike overlay: real-world-anchored markers over the feed.
  final StrikeOverlayController _overlayController = StrikeOverlayController();
  void Function()? _overlayEffectDispose;

  // Mini map: thumbnail lightning map in the top-left.
  final MiniMapController _miniMapController = MiniMapController();
  void Function()? _miniMapEffectDispose;

  // Volume button shutter via native platform channel
  static const _volumeKeyChannel = MethodChannel(
    'com.wisp.lightingcamera/volume_keys',
  );
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

    // Start/stop the overlay whenever the setting flips (and re-evaluated on
    // visibility changes via _syncOverlay).
    _overlayEffectDispose = effect(() {
      settingsManager.strikeOverlayEnabledSignal.value;
      _syncOverlay();
    });

    // Same for the mini map, against its own setting.
    _miniMapEffectDispose = effect(() {
      settingsManager.miniMapEnabledSignal.value;
      _syncMiniMap();
    });
  }

  /// Run the overlay only when the page is visible and the setting is on;
  /// otherwise tear it down so it does zero sensor/GPS work.
  void _syncOverlay() {
    if (_isPageVisible && settingsManager.strikeOverlayEnabled) {
      _overlayController.start();
    } else {
      _overlayController.stop();
    }
  }

  /// Run the mini map only when the page is visible and the setting is on;
  /// otherwise release its lightning connection.
  void _syncMiniMap() {
    if (_isPageVisible && settingsManager.miniMapEnabled) {
      _miniMapController.start();
    } else {
      _miniMapController.stop();
    }
  }

  Future<dynamic> _handleVolumeKey(MethodCall call) async {
    if (call.method == 'volumeKeyPressed' &&
        _volumeButtonsEnabled &&
        _isPageVisible) {
      final now = DateTime.now();
      if (_lastShutterTime == null ||
          now.difference(_lastShutterTime!) >
              const Duration(milliseconds: 300)) {
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
    _overlayEffectDispose?.call();
    _overlayController.stop();
    _miniMapEffectDispose?.call();
    _miniMapController.stop();
    _disposeCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _overlayController.stop();
      _miniMapController.stop();
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (_isPageVisible) {
        _initializeControllerFuture = _setupCamera();
        _syncOverlay();
        _syncMiniMap();
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
    _syncOverlay();
    _syncMiniMap();
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
    _syncOverlay();
    _syncMiniMap();
  }

  @override
  void didPushNext() {
    _isPageVisible = false;
    _volumeButtonsEnabled = false;
    if (isRecording) {
      _stopRecording();
    }
    _syncOverlay();
    _syncMiniMap();
  }

  @override
  void didPop() {
    _isPageVisible = false;
    _volumeButtonsEnabled = false;
    if (isRecording) {
      _stopRecording();
    }
    _syncOverlay();
    _syncMiniMap();
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

    // CameraX can throw transiently during initialize() — e.g. the preview's
    // resolution isn't ready yet and the plugin's internal null check fails
    // (a plain TypeError, not a CameraException). Retry with a fresh
    // controller a few times before giving up.
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final newController = CameraController(
        selectedCamera,
        ResolutionPreset.high,
      );
      try {
        await newController.initialize();

        if (newController.value.isInitialized) {
          _minExposureCompensation = await newController.getMinExposureOffset();
          _maxExposureCompensation = await newController.getMaxExposureOffset();
        }

        if (!mounted) {
          await newController.dispose();
          return;
        }

        controller = newController;
        break;
      } catch (e, st) {
        Fimber.e(
          'Error initializing camera (attempt $attempt/$maxAttempts): $e',
          ex: e,
          stacktrace: st,
        );
        await newController.dispose();
        if (attempt == maxAttempts || !mounted) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
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
    final cam = controller;
    if (cam == null) {
      return;
    }

    if (isRecording) {
      try {
        await cam.stopImageStream();
      } catch (e) {
        Fimber.e('Error stopping image stream: $e', ex: e);
      }
      isRecording = false;
      WakelockPlus.disable();
    }

    // Clear the field and rebuild so CameraPreview is removed from the widget
    // tree *before* the controller is disposed. Otherwise the still-mounted
    // CameraPreview can rebuild against a disposed controller (it listens to
    // the controller's own value) and throw "buildPreview() was called on a
    // disposed CameraController".
    controller = null;
    if (mounted) {
      setState(() {});
    }

    try {
      await cam.dispose();
    } catch (e) {
      Fimber.e('Error disposing camera: $e', ex: e);
    }
  }

  Future<void> _setExposureCompensation(double value) async {
    if (controller == null || !controller!.value.isInitialized) {
      return;
    }

    try {
      await controller!.setExposureOffset(value);
      _exposureCompensation = value;
    } catch (e) {
      Fimber.e('Error setting exposure compensation: $e', ex: e);
    }
  }

  Widget _buildVerticalExposureSlider() {
    const thumbRadius = 6.0;
    const trackWidth = 2.0;

    void handlePosition(double localY, double trackHeight) {
      final range = _maxExposureCompensation - _minExposureCompensation;
      if (range <= 0) return;
      final usableHeight = trackHeight - thumbRadius * 2;
      if (usableHeight <= 0) return;
      final clamped = (localY - thumbRadius).clamp(0.0, usableHeight);
      final normalized = 1.0 - clamped / usableHeight;
      final raw = _minExposureCompensation + normalized * range;
      final snapped = ((raw * 10).roundToDouble() / 10)
          .clamp(_minExposureCompensation, _maxExposureCompensation);
      setState(() => _sliderExposureValue = snapped);
      _setExposureCompensation(snapped);
    }

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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trackHeight = constraints.maxHeight;
                final range =
                    _maxExposureCompensation - _minExposureCompensation;
                final usableHeight = trackHeight - thumbRadius * 2;
                final normalized = range > 0
                    ? (_sliderExposureValue - _minExposureCompensation) / range
                    : 0.5;
                final thumbCenterY =
                    thumbRadius + usableHeight * (1.0 - normalized);

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) =>
                      handlePosition(details.localPosition.dy, trackHeight),
                  onVerticalDragStart: (details) =>
                      handlePosition(details.localPosition.dy, trackHeight),
                  onVerticalDragUpdate: (details) =>
                      handlePosition(details.localPosition.dy, trackHeight),
                  child: Stack(
                    alignment: Alignment.topCenter,
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        top: thumbRadius,
                        bottom: thumbRadius,
                        child: Container(
                          width: trackWidth,
                          color: Colors.white38,
                        ),
                      ),
                      Positioned(
                        top: thumbCenterY,
                        bottom: thumbRadius,
                        child: Container(
                          width: trackWidth,
                          color: Colors.white,
                        ),
                      ),
                      Positioned(
                        top: thumbCenterY - thumbRadius,
                        child: Container(
                          width: thumbRadius * 2,
                          height: thumbRadius * 2,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () {
              setState(() => _sliderExposureValue = 0.0);
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
    final topInset = MediaQuery.of(context).padding.top;
    // Leave room on the right for the settings/map/overlay button column so the
    // status box never slides under it.
    final maxBarWidth = MediaQuery.of(context).size.width - 64;

    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (controller != null &&
            _cameras != null &&
            controller!.value.isInitialized &&
            controller!.value.previewSize != null) {
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
              Positioned.fill(
                child: StrikeOverlay(controller: _overlayController),
              ),
              Positioned(
                top: topInset,
                left: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          settingsManager.setCacheInfoCollapsed(
                            !settingsManager.cacheInfoCollapsed,
                          );
                        });
                      },
                      child: Container(
                        constraints: BoxConstraints(maxWidth: maxBarWidth),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    'Caching the last ${cacheManager.getCacheDurationSeconds().toStringAsFixed(1)} seconds',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  settingsManager.cacheInfoCollapsed
                                      ? Icons.expand_more
                                      : Icons.expand_less,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ],
                            ),
                            if (!settingsManager.cacheInfoCollapsed) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Image Count: ${cacheManager.cacheSize.value} | FPS: $_fps | Cache: ${cacheManager.getCacheMemoryUsageMB().toStringAsFixed(1)}MB',
                                style: const TextStyle(color: Colors.white),
                              ),
                              Row(
                                children: [
                                  Icon(
                                    Icons.volume_up,
                                    color: _volumeButtonsEnabled
                                        ? Colors.green
                                        : Colors.orange,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Volume shutter: ${_volumeButtonsEnabled ? "Active" : "Inactive"}',
                                    style: TextStyle(
                                      color: _volumeButtonsEnabled
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
                          ],
                        ),
                      ),
                    ),
                    Watch((context) {
                      if (!settingsManager.miniMapEnabledSignal.value) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: MiniMap(controller: _miniMapController),
                      );
                    }),
                  ],
                ),
              ),
              Watch((context) {
                final offsetX = settingsManager.shutterOffsetXSignal.watch(
                  context,
                );
                final isRepositioning = settingsManager.isRepositioningSignal
                    .watch(context);
                _syncWiggle(isRepositioning);
                final currentOffset = _dragOffsetX ?? offsetX;
                return _buildShutterButton(currentOffset, isRepositioning);
              }),
              Watch((context) {
                final isRepositioning = settingsManager.isRepositioningSignal
                    .watch(context);
                if (!isRepositioning) return const SizedBox.shrink();
                return _buildSaveBar();
              }),
              Positioned(
                top: topInset + 8,
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
                    child: const Icon(
                      Icons.settings,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: topInset + 56,
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
                    child: const Icon(Icons.map, color: Colors.white, size: 22),
                  ),
                ),
              ),
              Positioned(
                top: topInset + 104,
                right: 8,
                child: Watch((context) {
                  final on = settingsManager.strikeOverlayEnabledSignal.value;
                  return GestureDetector(
                    onTap: () => settingsManager.setStrikeOverlayEnabled(!on),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        on
                            ? Icons.center_focus_strong
                            : Icons.center_focus_weak,
                        color: on ? Colors.amber : Colors.white,
                        size: 22,
                      ),
                    ),
                  );
                }),
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
          final angle =
              math.sin(_wiggleController.value * 2 * math.pi) * 0.087; // ±5°
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
      button = GestureDetector(onTap: _onShutterPressed, child: button);
    }

    return Positioned(bottom: 50, left: left, child: button);
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
