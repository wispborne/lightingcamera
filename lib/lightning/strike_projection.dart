import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:latlong2/latlong.dart';

/// Where a strike should be drawn on the camera overlay.
///
/// When [onScreen] is true, [position] is the pixel point to draw the marker at.
/// When false, the strike is outside the field of view: [position] is a point on
/// the screen edge and [angleRadians] is the direction (screen space, 0 = right,
/// increasing clockwise) an arrow there should point to lead the user toward it.
class StrikePlacement {
  final bool onScreen;
  final Offset position;
  final double angleRadians;

  const StrikePlacement({
    required this.onScreen,
    required this.position,
    this.angleRadians = 0,
  });
}

/// Initial bearing from [from] to [to], degrees clockwise from north (0=N, 90=E),
/// normalized to [0, 360).
double bearingDegrees(LatLng from, LatLng to) {
  final lat1 = _deg2rad(from.latitude);
  final lat2 = _deg2rad(to.latitude);
  final dLon = _deg2rad(to.longitude - from.longitude);
  final y = math.sin(dLon) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  var deg = _rad2deg(math.atan2(y, x));
  deg %= 360;
  if (deg < 0) deg += 360;
  return deg;
}

/// Projects a strike onto the camera overlay given where the user is, where the
/// strike is, and how the phone is oriented.
///
/// [deviceToWorld] is a row-major 3x3 rotation matrix mapping device coordinates
/// (x right, y up, z out of screen) to world coordinates (x East, y North,
/// z Up) — exactly what [OrientationService] publishes. Strikes are treated as
/// sitting on the horizon (elevation 0), since they're far away and at ground
/// level.
///
/// Returns null only if [deviceToWorld] is malformed.
StrikePlacement? projectStrike({
  required LatLng user,
  required LatLng strike,
  required List<double> deviceToWorld,
  required double horizontalFovDeg,
  required double verticalFovDeg,
  required Size screenSize,
}) {
  if (deviceToWorld.length != 9) return null;
  final m = deviceToWorld;

  // Strike direction in world frame (East, North, Up) on the horizon.
  final bearing = _deg2rad(bearingDegrees(user, strike));
  final wEast = math.sin(bearing);
  final wNorth = math.cos(bearing);
  const wUp = 0.0;

  // Rotate world direction into the device frame: dev = Rᵀ · world.
  // Columns of R (device→world) are the rows of Rᵀ.
  final devX = m[0] * wEast + m[3] * wNorth + m[6] * wUp;
  final devY = m[1] * wEast + m[4] * wNorth + m[7] * wUp;
  final devZ = m[2] * wEast + m[5] * wNorth + m[8] * wUp;

  final halfTanH = math.tan(_deg2rad(horizontalFovDeg) / 2);
  final halfTanV = math.tan(_deg2rad(verticalFovDeg) / 2);

  // The camera looks along device -Z, so a strike in front has devZ < 0.
  const forwardEps = -1e-4;
  if (devZ < forwardEps) {
    // Perspective divide. u = right, v = up, in units of tan(angle).
    final u = devX / -devZ;
    final v = devY / -devZ;
    final nx = u / halfTanH; // -1..1 across the screen width
    final ny = v / halfTanV; // -1..1 across the screen height
    if (nx.abs() <= 1 && ny.abs() <= 1) {
      return StrikePlacement(
        onScreen: true,
        position: _normToPixels(nx, ny, screenSize),
      );
    }
    return _edgeArrow(nx, ny, screenSize);
  }

  // Strike is at or behind the screen plane: point an edge arrow toward the
  // shorter way to turn, using the in-plane direction of the strike.
  return _edgeArrow(devX, devY, screenSize);
}

/// Builds an edge arrow for an off-screen direction given a screen-space vector
/// ([dx] right, [dy] up). The vector need not be normalized.
StrikePlacement _edgeArrow(double dx, double dy, Size size) {
  // Degenerate direction: park it at the right edge.
  if (dx == 0 && dy == 0) dx = 1;

  // Scale the ray so it lands on the unit box boundary (the screen edge).
  final t = 1 / math.max(dx.abs(), dy.abs());
  final ex = dx * t;
  final ey = dy * t;
  final pos = _normToPixels(ex, ey, size);

  // Arrow points outward from screen center, in pixel space (y grows downward).
  final cx = size.width / 2;
  final cy = size.height / 2;
  final angle = math.atan2(pos.dy - cy, pos.dx - cx);
  return StrikePlacement(onScreen: false, position: pos, angleRadians: angle);
}

/// Maps normalized coords ([nx] right, [ny] up, both -1..1) to screen pixels.
Offset _normToPixels(double nx, double ny, Size size) {
  final x = (nx + 1) / 2 * size.width;
  final y = (1 - ny) / 2 * size.height; // screen y grows downward
  return Offset(x, y);
}

/// Projects a compass bearing onto the camera overlay using the same math as
/// [projectStrike] but skipping the geo-to-bearing step.
StrikePlacement? projectBearing({
  required double bearingDeg,
  required List<double> deviceToWorld,
  required double horizontalFovDeg,
  required double verticalFovDeg,
  required Size screenSize,
}) {
  if (deviceToWorld.length != 9) return null;
  final m = deviceToWorld;

  final bearing = _deg2rad(bearingDeg);
  final wEast = math.sin(bearing);
  final wNorth = math.cos(bearing);
  const wUp = 0.0;

  final devX = m[0] * wEast + m[3] * wNorth + m[6] * wUp;
  final devY = m[1] * wEast + m[4] * wNorth + m[7] * wUp;
  final devZ = m[2] * wEast + m[5] * wNorth + m[8] * wUp;

  final halfTanH = math.tan(_deg2rad(horizontalFovDeg) / 2);
  final halfTanV = math.tan(_deg2rad(verticalFovDeg) / 2);

  const forwardEps = -1e-4;
  if (devZ < forwardEps) {
    final u = devX / -devZ;
    final v = devY / -devZ;
    final nx = u / halfTanH;
    final ny = v / halfTanV;
    if (nx.abs() <= 1 && ny.abs() <= 1) {
      return StrikePlacement(
        onScreen: true,
        position: _normToPixels(nx, ny, screenSize),
      );
    }
    return _edgeArrow(nx, ny, screenSize);
  }

  return _edgeArrow(devX, devY, screenSize);
}

double _deg2rad(double d) => d * math.pi / 180.0;
double _rad2deg(double r) => r * 180.0 / math.pi;
