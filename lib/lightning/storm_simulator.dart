import 'dart:async';
import 'dart:math';

import 'package:latlong2/latlong.dart';

/// Simulates a storm front sweeping across an area for test mode.
///
/// A front is a line that travels across a disc of [radiusKm] around [center].
/// Each tick it advances a step and drops a few tightly clustered cells of
/// strikes behind its leading edge; when it exits one side a new front enters
/// from a fresh direction. It knows nothing about networking or signals — it
/// just calls [onStrike] with each generated position.
class StormSimulator {
  StormSimulator({
    required this.center,
    required this.radiusKm,
    required this.onStrike,
    this.interval = const Duration(seconds: 20),
  });

  /// Center of the simulated area (the user's GPS location).
  final LatLng center;

  /// Strikes stay within this distance of [center].
  final double radiusKm;

  /// Called once per generated strike position.
  final void Function(LatLng point) onStrike;

  /// How often the front advances and drops a burst.
  final Duration interval;

  // --- Storm-front tuning ---
  /// How far the front advances each tick, as a fraction of a full crossing.
  /// ~0.06 ≈ a full pass every ~17 ticks.
  static const double _stormStep = 0.06;

  /// Number of active storm cells dropped along the front each tick.
  static const int _cellsPerTick = 2;

  /// Strikes dropped per cell each tick.
  static const int _strikesPerCell = 2;

  /// Roughly how tightly strikes cluster around a cell center (km).
  static const double _cellSpreadKm = 4.0;

  /// How far behind the leading edge strikes trail (km). Storms light up behind
  /// the front, not ahead of it.
  static const double _frontDepthKm = 8.0;

  final Random _random = Random();
  Timer? _timer;

  /// Direction the front is travelling (degrees, compass bearing).
  double _bearing = 0;

  /// Front position along its travel axis, 0 (entering) → 1 (exited).
  double _progress = 0;

  bool get isRunning => _timer != null;

  /// Begin simulating. Fires one burst immediately, then every [interval].
  void start() {
    _startNewFront();
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// Stop simulating and reset the front.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _progress = 0;
  }

  /// Pick a fresh travel direction and reset the front to the entering edge.
  void _startNewFront() {
    _bearing = _random.nextDouble() * 360;
    _progress = 0;
  }

  /// Advance the front one step and drop a clustered burst of strikes along it.
  void _tick() {
    // The front is a line perpendicular to its travel direction. `along` runs
    // in the travel direction; `cross` runs along the front line itself.
    final crossBearing = (_bearing + 90) % 360;

    // Leading edge sweeps from one side of the disc to the other.
    final frontAlongKm = (_progress * 2 - 1) * radiusKm;

    for (var c = 0; c < _cellsPerTick; c++) {
      // Each cell sits somewhere along the front line.
      final cellCrossKm = (_random.nextDouble() * 2 - 1) * radiusKm;

      for (var s = 0; s < _strikesPerCell; s++) {
        // Strikes scatter around the cell, and trail *behind* the leading edge.
        final alongKm = frontAlongKm -
            (_random.nextDouble() * _frontDepthKm) +
            _gaussian() * _cellSpreadKm;
        final crossKm = cellCrossKm + _gaussian() * _cellSpreadKm;

        var point = _offsetKm(center, alongKm, _bearing);
        point = _offsetKm(point, crossKm, crossBearing);

        // Keep it inside the area we advertise.
        if (const Distance().as(LengthUnit.Kilometer, center, point) >
            radiusKm) {
          continue;
        }
        onStrike(point);
      }
    }

    _progress += _stormStep;
    if (_progress >= 1) {
      // Front has crossed; spin up a new one from a different direction.
      _startNewFront();
    }
  }

  /// Move [from] by [km] along compass [bearingDeg]; negative [km] flips it 180°.
  LatLng _offsetKm(LatLng from, double km, double bearingDeg) {
    if (km == 0) return from;
    final bearing = km >= 0 ? bearingDeg : (bearingDeg + 180) % 360;
    return const Distance().offset(from, (km.abs() * 1000).round(), bearing);
  }

  /// Standard-normal sample (Box–Muller). Used to cluster strikes around cells.
  double _gaussian() {
    final u1 = _random.nextDouble().clamp(1e-9, 1.0);
    final u2 = _random.nextDouble();
    return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
  }
}
