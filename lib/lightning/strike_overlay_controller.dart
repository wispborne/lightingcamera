import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:signals/signals.dart';

import 'package:lightingcamera/lightning/camera_fov.dart';
import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/sensors/orientation_service.dart';
import 'package:lightingcamera/utils/logging.dart';

/// Owns the live state the camera strike overlay needs: the user's GPS fix, the
/// camera's field of view, and the orientation subscription. It also drives the
/// shared [lightningService] connection via ref-counted acquire/release so the
/// camera and map pages don't disconnect each other.
///
/// One instance per camera page. Call [start] when the overlay should run (page
/// visible AND the setting on) and [stop] otherwise — [stop] tears everything
/// down so a disabled overlay does zero sensor/GPS work.
class StrikeOverlayController {
  final Signal<LatLng?> _userLocation = signal(null);
  ReadonlySignal<LatLng?> get userLocation => _userLocation;

  final Signal<double> _horizontalFovDeg =
      signal(CameraFov.defaultHorizontalFovDegrees);
  ReadonlySignal<double> get horizontalFovDeg => _horizontalFovDeg;

  /// Current zoom ratio of the camera preview, pushed in by the camera page.
  /// The overlay narrows its projection to match — at 2× the visible field of
  /// view is half as wide.
  final Signal<double> _zoom = signal(1.0);
  ReadonlySignal<double> get zoom => _zoom;

  void setZoom(double zoom) {
    if (zoom > 0) _zoom.value = zoom;
  }

  bool _active = false;
  bool _acquired = false;

  /// Counts calls to [start], so a start that was still waiting on its GPS fix
  /// when a stop/start pair ran can tell it has been superseded. Without this,
  /// both the old and new start would acquire the lightning connection, and the
  /// single release in [stop] would leak one hold forever.
  int _startEpoch = 0;

  /// Begin the overlay's work: orientation sensor, FOV query, GPS fix, and the
  /// shared lightning connection. Idempotent.
  Future<void> start() async {
    if (_active) return;
    _active = true;
    orientationService.start();
    _loadFov();
    await _resolveAndConnect(++_startEpoch);
  }

  /// Stop all overlay work and release the lightning connection. Idempotent.
  void stop() {
    if (!_active) return;
    _active = false;
    orientationService.stop();
    if (_acquired) {
      lightningService.release();
      _acquired = false;
    }
  }

  Future<void> _loadFov() async {
    final fov = await CameraFov.horizontalFovDegrees();
    if (_active) _horizontalFovDeg.value = fov;
  }

  Future<void> _resolveAndConnect(int epoch) async {
    final center = await _resolveLocation();
    // The user may have left or disabled the overlay while we awaited the fix,
    // or a newer start may have taken over.
    if (!_active || epoch != _startEpoch) return;
    if (center == null) return; // no location → overlay stays hidden
    _userLocation.value = center;
    lightningService.acquire(center);
    _acquired = true;
  }

  /// Resolve the user's location, or null if it's unavailable or denied. Mirrors
  /// the lightning map page's permission handling, but the overlay simply hides
  /// itself rather than falling back to a default area.
  Future<LatLng?> _resolveLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition();
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      Fimber.e('Overlay location lookup failed: $e');
      return null;
    }
  }
}
