import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';
import 'package:signals/signals.dart';

import 'package:lightingcamera/utils/logging.dart';

/// Streams the phone's fused absolute orientation as a device→world rotation
/// matrix, so callers can work out where the camera is pointing in the real
/// world.
///
/// The underlying source is Android's `TYPE_ROTATION_VECTOR` (compass +
/// accelerometer + gyro, fused by the OS) via `flutter_rotation_sensor`. We use
/// the rotation matrix rather than azimuth/pitch/roll because a phone held
/// upright like a camera puts the device's "up" axis toward the sky, which makes
/// the compass azimuth ill-defined (gimbal lock). Transforming a strike's world
/// direction through the matrix sidesteps that and folds heading, tilt, and roll
/// into one step.
///
/// Top-level singleton, matching `lightningService` / `settingsManager`.
final orientationService = OrientationService();

class OrientationService {
  /// The device→world rotation matrix, row-major (9 elements). World axes are
  /// x = East, y = North, z = Up — matching `flutter_rotation_sensor`. `null`
  /// when no reading has arrived yet or the platform has no rotation sensor.
  final Signal<List<double>?> _rotationMatrix = signal(null);
  ReadonlySignal<List<double>?> get rotationMatrix => _rotationMatrix;

  /// Whether usable orientation data is currently available.
  final Signal<bool> _available = signal(false);
  ReadonlySignal<bool> get available => _available;

  /// Estimated heading accuracy in radians from the rotation sensor. Negative
  /// means unavailable (iOS, or old Android devices). Values above ~0.52 rad
  /// (≈ 30°) indicate the magnetometer needs recalibration.
  final Signal<double> _accuracyRad = signal(-1);
  ReadonlySignal<double> get accuracyRad => _accuracyRad;

  /// Threshold in radians above which we consider accuracy poor enough to
  /// prompt the user. ~30° — direction labels can be a full compass point off.
  static const double poorAccuracyThreshold = 0.55;

  StreamSubscription<OrientationEvent>? _subscription;

  /// Exponential-smoothing weight applied to each new reading (0..1). Higher is
  /// snappier but jitterier. Light smoothing keeps markers from shimmering.
  static const double _smoothing = 0.35;

  // Smoothed quaternion state (x, y, z, w).
  double _qx = 0, _qy = 0, _qz = 0, _qw = 1;
  bool _hasSample = false;

  /// Begin listening to the rotation sensor. Safe to call when already started.
  void start() {
    if (_subscription != null) return;

    if (!RotationSensor.isPlatformSupported) {
      Fimber.w('Rotation sensor not supported on this platform.');
      _available.value = false;
      return;
    }

    RotationSensor.samplingPeriod = SensorInterval.gameInterval;
    _hasSample = false;
    _subscription = RotationSensor.orientationStream.listen(
      _onEvent,
      onError: (Object e) {
        Fimber.e('Rotation sensor error: $e');
        _available.value = false;
      },
    );
  }

  /// Stop listening and drop the current reading so the overlay hides.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _hasSample = false;
    _rotationMatrix.value = null;
    _available.value = false;
    _accuracyRad.value = -1;
  }

  void _onEvent(OrientationEvent event) {
    _accuracyRad.value = event.accuracy;

    final q = event.quaternion;
    var nx = q.x, ny = q.y, nz = q.z, nw = q.w;

    // Normalize defensively.
    final len = _length4(nx, ny, nz, nw);
    if (len == 0) return;
    nx /= len;
    ny /= len;
    nz /= len;
    nw /= len;

    if (!_hasSample) {
      _qx = nx;
      _qy = ny;
      _qz = nz;
      _qw = nw;
      _hasSample = true;
    } else {
      // Align signs (q and -q are the same rotation) before blending, otherwise
      // smoothing can take the long way around.
      if (_dot4(_qx, _qy, _qz, _qw, nx, ny, nz, nw) < 0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
        nw = -nw;
      }
      const a = _smoothing;
      _qx = _qx * (1 - a) + nx * a;
      _qy = _qy * (1 - a) + ny * a;
      _qz = _qz * (1 - a) + nz * a;
      _qw = _qw * (1 - a) + nw * a;
      final l = _length4(_qx, _qy, _qz, _qw);
      if (l == 0) return;
      _qx /= l;
      _qy /= l;
      _qz /= l;
      _qw /= l;
    }

    _rotationMatrix.value = _quaternionToMatrix(_qx, _qy, _qz, _qw);
    _available.value = true;
  }

  /// Compass bearing of the camera (back of the phone), 0=N, 90=E, in degrees.
  /// For logging/diagnostics; the overlay uses the matrix directly.
  double? get headingDegrees {
    final m = _rotationMatrix.value;
    if (m == null) return null;
    // Camera forward = device -Z mapped to world = -column2 = (-m[2],-m[5],-m[8]).
    final east = -m[2];
    final north = -m[5];
    var deg = _radToDeg(math.atan2(east, north));
    if (deg < 0) deg += 360;
    return deg;
  }

  /// Elevation of the camera's optical axis above the horizon, in degrees.
  double? get pitchDegrees {
    final m = _rotationMatrix.value;
    if (m == null) return null;
    final up = -m[8]; // z (Up) component of camera forward
    return _radToDeg(math.asin(up.clamp(-1.0, 1.0)));
  }

  static double _length4(double x, double y, double z, double w) =>
      math.sqrt(x * x + y * y + z * z + w * w);

  static double _dot4(double ax, double ay, double az, double aw, double bx,
          double by, double bz, double bw) =>
      ax * bx + ay * by + az * bz + aw * bw;

  /// Row-major device→world rotation matrix from a unit quaternion.
  static List<double> _quaternionToMatrix(
      double x, double y, double z, double w) {
    final xx = x * x, yy = y * y, zz = z * z;
    final xy = x * y, xz = x * z, yz = y * z;
    final wx = w * x, wy = w * y, wz = w * z;
    return [
      1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy),
      2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx),
      2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy),
    ];
  }
}

double _radToDeg(double r) => r * 180.0 / math.pi;
