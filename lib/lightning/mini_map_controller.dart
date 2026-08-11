import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:signals/signals.dart';

import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/utils/logging.dart';

/// Owns the live state the camera-page mini map needs: the user's GPS fix and a
/// ref-counted hold on the shared [lightningService] so its strikes flow in.
///
/// One instance per camera page. Call [start] when the mini map should run (page
/// visible AND the setting on) and [stop] otherwise — [stop] releases the
/// lightning connection so a disabled mini map does no work. Mirrors
/// [StrikeOverlayController] but without orientation or field-of-view, since the
/// mini map is a flat top-down view.
class MiniMapController {
  final Signal<LatLng?> _userLocation = signal(null);
  ReadonlySignal<LatLng?> get userLocation => _userLocation;

  bool _active = false;
  bool _acquired = false;

  /// Counts calls to [start], so a start that was still waiting on its GPS fix
  /// when a stop/start pair ran can tell it has been superseded. Without this,
  /// both the old and new start would acquire the lightning connection, and the
  /// single release in [stop] would leak one hold forever.
  int _startEpoch = 0;

  /// Resolve the user's location and open the shared lightning connection.
  /// Idempotent.
  Future<void> start() async {
    if (_active) return;
    _active = true;
    final epoch = ++_startEpoch;
    final center = await _resolveLocation();
    // The user may have left or disabled the mini map while we awaited the fix,
    // or a newer start may have taken over.
    if (!_active || epoch != _startEpoch) return;
    if (center == null) return; // no location → mini map stays hidden
    _userLocation.value = center;
    lightningService.acquire(center);
    _acquired = true;
  }

  /// Release the lightning connection. Idempotent.
  void stop() {
    if (!_active) return;
    _active = false;
    if (_acquired) {
      lightningService.release();
      _acquired = false;
    }
  }

  /// Resolve the user's location, or null if it's unavailable or denied. Matches
  /// the overlay controller's handling — the mini map simply hides itself rather
  /// than falling back to a default area.
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
      Fimber.e('Mini map location lookup failed: $e');
      return null;
    }
  }
}
