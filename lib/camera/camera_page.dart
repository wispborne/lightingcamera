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
import 'package:lightingcamera/utils/volume_key_dispatcher.dart';
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

  // Opening and closing the camera both touch the same hardware and mutate
  // `controller`, so they must never overlap. Every setup/teardown is chained
  // onto this future so they run strictly one-at-a-time. Without this, rapid
  // lifecycle events (e.g. notifications during a storm) could start a new
  // open() before the previous close() released the camera, leaving it stuck
  // "in use" until the whole app was restarted.
  Future<void> _cameraOps = Future.value();
  // True when every initialize() attempt failed; the UI shows a retry button
  // instead of an endless spinner.
  bool _cameraInitFailed = false;

  // The capture shape the current controller was opened with. Used to detect
  // when the user changes the aspect-ratio setting so we can reconnect.
  CaptureAspect? _appliedAspect;
  void Function()? _captureAspectEffectDispose;

  /// Maps the capture-shape setting to a camera resolution. The 16:9 stream is
  /// sharper; the 4:3 stream keeps the sensor's full height (a taller view) at a
  /// lower resolution.
  ResolutionPreset _resolutionPresetFor(CaptureAspect aspect) =>
      aspect == CaptureAspect.full4x3
      ? ResolutionPreset.medium
      : ResolutionPreset.high;

  img_lib.Image? displayImage;
  int _imagesCapturedLastSecond = 0;
  int _fps = 0;
  bool showLivePreview = false;
  // The phone's current orientation. A signal so the shutter button can react
  // to rotation and show the position saved for that orientation. Also drives
  // per-frame rotation in the capture stream.
  final Signal<DeviceOrientation> _currentOrientation = signal(
    DeviceOrientation.portraitUp,
  );

  // Exposure compensation variables
  double _exposureCompensation = 0.0;
  double _sliderExposureValue = 0.0;
  double _minExposureCompensation = -2.0;
  double _maxExposureCompensation = 2.0;

  // Pinch-to-zoom. The range is whatever the lens reports (e.g. 0.5×–30× on a
  // phone with an ultra-wide); _currentZoom is the live ratio and
  // _zoomAtGestureStart anchors a pinch so it scales smoothly.
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  double _zoomAtGestureStart = 1.0;

  // Wiggle animation for reposition mode
  late final AnimationController _wiggleController;
  // Live position (0..1 of the travel region) while a reposition drag is in
  // progress; null when not dragging.
  Offset? _dragOffset;

  // Strike overlay: real-world-anchored markers over the feed.
  final StrikeOverlayController _overlayController = StrikeOverlayController();
  void Function()? _overlayEffectDispose;

  // Mini map: thumbnail lightning map in the top-left.
  final MiniMapController _miniMapController = MiniMapController();
  void Function()? _miniMapEffectDispose;

  // Volume button shutter — fed by the shared volume-key dispatcher so the
  // gallery can take over the keys while it covers this page without breaking
  // the shutter when we come back.
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
    volumeKeyDispatcher.subscribe(_handleVolumeKey);

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

    // Reconnect the camera at the new resolution whenever the capture-shape
    // setting changes. The first run just records the starting value — the
    // initial open is handled by _initializeCamera above.
    _captureAspectEffectDispose = effect(() {
      final aspect = settingsManager.captureAspectSignal.value;
      if (_appliedAspect == null || aspect == _appliedAspect) {
        return;
      }
      _appliedAspect = aspect;
      _initializeControllerFuture = _runCameraOp(() async {
        await _disposeCamera();
        await _setupCamera();
      });
      if (mounted) setState(() {});
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

  void _handleVolumeKey() {
    if (!_volumeButtonsEnabled || !_isPageVisible) return;
    final now = DateTime.now();
    if (_lastShutterTime == null ||
        now.difference(_lastShutterTime!) > const Duration(milliseconds: 300)) {
      _lastShutterTime = now;
      _onShutterPressed();
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
    volumeKeyDispatcher.unsubscribe(_handleVolumeKey);
    _overlayEffectDispose?.call();
    _overlayController.stop();
    _miniMapEffectDispose?.call();
    _miniMapController.stop();
    _captureAspectEffectDispose?.call();
    _runCameraOp(_disposeCamera);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _overlayController.stop();
      _miniMapController.stop();
      _runCameraOp(_disposeCamera);
    } else if (state == AppLifecycleState.resumed) {
      if (_isPageVisible) {
        _initializeControllerFuture = _runCameraOp(_setupCamera);
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
    if (controller == null) {
      // Camera was released when another page covered this one — reconnect.
      _initializeControllerFuture = _runCameraOp(_setupCamera);
      setState(() {});
    } else if (controller!.value.isInitialized) {
      controller!.resumePreview();
      if (!isRecording) {
        _startRecording();
      }
    }
    _syncOverlay();
    _syncMiniMap();
  }

  @override
  void didPushNext() {
    // Routing can fire this spuriously while the navigator reconciles its stack
    // (e.g. returning from the gallery). If we're actually still the topmost
    // route, nothing covered us — ignore it, otherwise we'd dispose the camera
    // right after reopening it and hang on a spinner.
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      return;
    }
    _isPageVisible = false;
    _volumeButtonsEnabled = false;
    // Fully release the camera while another page covers this one — keeping
    // the hardware connected just to pause the preview wastes battery.
    _runCameraOp(_disposeCamera);
    _syncOverlay();
    _syncMiniMap();
  }

  @override
  void didPop() {
    _isPageVisible = false;
    _volumeButtonsEnabled = false;
    _runCameraOp(_disposeCamera);
    _syncOverlay();
    _syncMiniMap();
  }

  /// Chains a camera open/close operation onto [_cameraOps] so it can't run
  /// concurrently with another one. A failed op never breaks the chain.
  Future<void> _runCameraOp(Future<void> Function() op) {
    final next = _cameraOps.then((_) => op());
    _cameraOps = next.catchError((_) {});
    return next;
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

    await _runCameraOp(_setupCamera);
  }

  Future<void> _setupCamera() async {
    // Already have a working camera — don't open a second connection on top of
    // it (just make sure it's recording).
    if (controller != null && controller!.value.isInitialized) {
      if (_isPageVisible && !isRecording) {
        _startRecording();
      }
      return;
    }
    // A half-open controller is lingering — release it first so we never hold
    // two camera connections at once.
    if (controller != null) {
      await _disposeCamera();
    }

    if (_cameraInitFailed && mounted) {
      setState(() => _cameraInitFailed = false);
    }

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
    final aspect = settingsManager.captureAspect;
    _appliedAspect = aspect;
    final preset = _resolutionPresetFor(aspect);

    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final newController = CameraController(selectedCamera, preset);
      try {
        await newController.initialize();

        if (newController.value.isInitialized) {
          _minExposureCompensation = await newController.getMinExposureOffset();
          _maxExposureCompensation = await newController.getMaxExposureOffset();

          // Learn the lens's real zoom range. On phones with an ultra-wide the
          // minimum is below 1.0 (e.g. 0.5×), which is how we let the user pull
          // back wider than the stock "1×".
          _minZoom = await newController.getMinZoomLevel();
          _maxZoom = await newController.getMaxZoomLevel();
          // Reapply the user's remembered zoom, clamped to what this lens
          // supports, so framing survives reconnects and restarts.
          _currentZoom = settingsManager.cameraZoom.clamp(_minZoom, _maxZoom);
          await newController.setZoomLevel(_currentZoom);
        }

        if (!mounted || !_isPageVisible) {
          // The page went away (or got covered) while the camera was
          // connecting — release it instead of holding it in the background.
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

    if (controller == null) {
      // Every attempt failed and the camera is still not open. Surface a retry
      // button instead of leaving the user stuck on an endless spinner (which
      // previously could only be escaped by restarting the app).
      if (_isPageVisible) {
        setState(() => _cameraInitFailed = true);
      }
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

  void _onScaleStart(ScaleStartDetails details) {
    _zoomAtGestureStart = _currentZoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Single-finger pans also fire here with scale == 1; only react to pinches.
    if (details.pointerCount < 2) return;
    _setZoom(_zoomAtGestureStart * details.scale);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Remember the framing so the camera reopens here next time.
    settingsManager.setCameraZoom(_currentZoom);
  }

  Future<void> _setZoom(double zoom) async {
    if (controller == null || !controller!.value.isInitialized) return;
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    if (clamped == _currentZoom) return;
    setState(() => _currentZoom = clamped);
    try {
      await controller!.setZoomLevel(clamped);
    } catch (e) {
      Fimber.e('Error setting zoom: $e', ex: e);
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

    // Controls in this page float over the live camera preview, so they use
    // white-on-black-scrim rather than theme colors — cyan-on-navy chrome would
    // wash out over arbitrary, bright camera frames. These stay hard-coded by
    // design for legibility, not as a theme oversight.
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

  /// A small pill showing the live zoom ratio. Tap it to reset to 1×. Hidden
  /// when the lens can't zoom (min and max are the same).
  Widget _buildZoomIndicator() {
    if (_maxZoom <= _minZoom) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () async {
        await _setZoom(1.0);
        settingsManager.setCameraZoom(_currentZoom);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          '${_currentZoom.toStringAsFixed(1)}×',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
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
          // previewSize is reported in the sensor's native (landscape) frame,
          // so its width is always the long edge. CameraPreview rotates its
          // contents to match the device orientation, so the box we wrap it in
          // has to flip shape too — otherwise a landscape preview gets crammed
          // into a portrait-shaped box and ends up letterboxed with black side
          // bars and a squished image.
          final previewSize = controller!.value.previewSize!;
          final previewIsLandscape =
              controller!.value.deviceOrientation ==
                  DeviceOrientation.landscapeLeft ||
              controller!.value.deviceOrientation ==
                  DeviceOrientation.landscapeRight;
          final previewBoxWidth = previewIsLandscape
              ? previewSize.width
              : previewSize.height;
          final previewBoxHeight = previewIsLandscape
              ? previewSize.height
              : previewSize.width;
          return Stack(
            children: [
              NativeDeviceOrientationReader(
                builder: (context) {
                  final orientation =
                      NativeDeviceOrientationReader.orientation(
                        context,
                      ).deviceOrientation ??
                      DeviceOrientation.portraitUp;
                  // Defer the update a frame so we never mutate a signal that the
                  // shutter button's Watch is reading in this same build pass.
                  if (_currentOrientation.value != orientation) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _currentOrientation.value = orientation;
                    });
                  }
                  return SizedBox.expand(
                    child: FittedBox(
                      // Show the whole frame (letterboxed) rather than cropping
                      // the edges to fill the screen — cropping made the view
                      // look far more zoomed-in than what's actually captured.
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: previewBoxWidth,
                        height: previewBoxHeight,
                        child: CameraPreview(controller!),
                      ),
                    ),
                  );
                },
              ),
              // Pinch anywhere on the feed to zoom. Sits above the preview but
              // below the overlay and the on-screen controls, so the strike
              // markers, shutter, and buttons keep their own gestures.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onScaleEnd: _onScaleEnd,
                ),
              ),
              Positioned.fill(
                child: StrikeOverlay(
                  controller: _overlayController,
                  // The on-screen frame's shape, so the overlay can line its
                  // markers up with the letterboxed image instead of the full
                  // screen.
                  previewAspectRatio: previewBoxWidth / previewBoxHeight,
                ),
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
              SignalBuilder(builder: (context) {
                final orientation = _currentOrientation.value;
                final stored = settingsManager.shutterOffsetFor(orientation);
                final isRepositioning =
                    settingsManager.isRepositioningSignal.value;
                _syncWiggle(isRepositioning);
                final currentOffset = _dragOffset ?? stored;
                return _buildShutterButton(
                  orientation,
                  currentOffset,
                  isRepositioning,
                );
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
              Positioned(
                bottom: 150,
                left: 0,
                right: 0,
                child: Center(child: _buildZoomIndicator()),
              ),
            ],
          );
        } else if (_cameraInitFailed) {
          return _buildCameraError(context);
        } else {
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }

  Widget _buildCameraError(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_off,
              size: 48,
              color: colorScheme.onSurface,
            ),
            const SizedBox(height: 16),
            Text(
              "Couldn't open the camera.",
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              onPressed: () {
                setState(() {
                  _cameraInitFailed = false;
                  _initializeControllerFuture = _runCameraOp(_setupCamera);
                });
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  static const _buttonSize = 80.0;
  // Margin kept between the button and the screen edges as it travels.
  static const _buttonEdgeMargin = 16.0;
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

  Widget _buildShutterButton(
    DeviceOrientation orientation,
    Offset offset,
    bool isRepositioning,
  ) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final insets = media.padding;

    // The region the button's top-left corner can occupy: anywhere on screen,
    // kept a small margin clear of the edges and out from under the status and
    // navigation bars.
    final minLeft = _buttonEdgeMargin;
    final minTop = insets.top + _buttonEdgeMargin;
    final travelWidth =
        size.width - _buttonSize - _buttonEdgeMargin - minLeft;
    final travelHeight =
        size.height - _buttonSize - insets.bottom - _buttonEdgeMargin - minTop;
    final left = minLeft + travelWidth.clamp(0.0, double.infinity) * offset.dx;
    final top = minTop + travelHeight.clamp(0.0, double.infinity) * offset.dy;

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
        onPanUpdate: (details) {
          if (travelWidth <= 0 && travelHeight <= 0) return;
          final current =
              _dragOffset ?? settingsManager.shutterOffsetFor(orientation);
          final dx = travelWidth > 0 ? details.delta.dx / travelWidth : 0.0;
          final dy = travelHeight > 0 ? details.delta.dy / travelHeight : 0.0;
          setState(() {
            _dragOffset = Offset(
              (current.dx + dx).clamp(0.0, 1.0),
              (current.dy + dy).clamp(0.0, 1.0),
            );
          });
        },
        onPanEnd: (details) {
          if (_dragOffset != null) {
            settingsManager.setShutterOffset(orientation, _dragOffset!);
            _dragOffset = null;
          }
        },
        child: button,
      );
    } else {
      button = GestureDetector(onTap: _onShutterPressed, child: button);
    }

    return Positioned(left: left, top: top, child: button);
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

        DeviceOrientation orientation = _currentOrientation.value;

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
}
