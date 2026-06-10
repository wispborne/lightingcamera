import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:lightingcamera/lightning/strike_projection.dart';

// Device→world rotation matrix for a phone held upright (portrait), level
// (camera axis on the horizon), pointing at compass [headingDeg]. Row-major,
// world axes x=East, y=North, z=Up.
List<double> levelMatrix(double headingDeg) {
  final h = headingDeg * math.pi / 180.0;
  final ch = math.cos(h);
  final sh = math.sin(h);
  return [
    ch, 0, -sh,
    -sh, 0, -ch,
    0, 1, 0,
  ];
}

// Standard 3x3 rotation about the Z axis, row-major.
List<double> rotZ(double rad) {
  final c = math.cos(rad);
  final s = math.sin(rad);
  return [
    c, -s, 0,
    s, c, 0,
    0, 0, 1,
  ];
}

// Row-major 3x3 multiply: a · b.
List<double> matmul(List<double> a, List<double> b) {
  final r = List<double>.filled(9, 0);
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      var sum = 0.0;
      for (var k = 0; k < 3; k++) {
        sum += a[row * 3 + k] * b[k * 3 + col];
      }
      r[row * 3 + col] = sum;
    }
  }
  return r;
}

void main() {
  const size = Size(1000, 1000);
  const fov = 90.0; // square screen + square FOV keeps roll a pure rotation
  final user = const LatLng(0, 0);
  final north = const LatLng(1, 0); // due north of user
  final east = const LatLng(0, 1); // due east of user
  final south = const LatLng(-1, 0); // due south of user

  test('bearingDegrees points the right way', () {
    expect(bearingDegrees(user, north), closeTo(0, 0.5));
    expect(bearingDegrees(user, east), closeTo(90, 0.5));
    expect(bearingDegrees(user, south), closeTo(180, 0.5));
  });

  test('strike dead ahead lands at screen center', () {
    final p = projectStrike(
      user: user,
      strike: north,
      deviceToWorld: levelMatrix(0),
      horizontalFovDeg: fov,
      verticalFovDeg: fov,
      screenSize: size,
    )!;
    expect(p.onScreen, isTrue);
    expect(p.position.dx, closeTo(500, 1));
    expect(p.position.dy, closeTo(500, 1));
  });

  test('strike within FOV to the right sits right of center, on the horizon', () {
    // 20° east of north, phone facing north → inside the 90° FOV, to the right.
    final strike = LatLng(
      math.cos(20 * math.pi / 180), // lat
      math.sin(20 * math.pi / 180), // lon — small-angle, bearing ≈ 20°
    );
    final p = projectStrike(
      user: user,
      strike: strike,
      deviceToWorld: levelMatrix(0),
      horizontalFovDeg: fov,
      verticalFovDeg: fov,
      screenSize: size,
    )!;
    expect(p.onScreen, isTrue);
    expect(p.position.dx, greaterThan(520));
    expect(p.position.dy, closeTo(500, 2));
  });

  test('strike to the side is off-screen with an arrow pointing right', () {
    final p = projectStrike(
      user: user,
      strike: east,
      deviceToWorld: levelMatrix(0),
      horizontalFovDeg: fov,
      verticalFovDeg: fov,
      screenSize: size,
    )!;
    expect(p.onScreen, isFalse);
    expect(p.position.dx, closeTo(1000, 1)); // pinned to the right edge
    expect(p.angleRadians, closeTo(0, 0.01)); // arrow points right
  });

  test('strike behind the user is off-screen', () {
    final p = projectStrike(
      user: user,
      strike: south,
      deviceToWorld: levelMatrix(0),
      horizontalFovDeg: fov,
      verticalFovDeg: fov,
      screenSize: size,
    )!;
    expect(p.onScreen, isFalse);
  });

  test('rolling the phone rotates the marker about center, preserving radius', () {
    // 20° east of north, on the horizon.
    final strike = LatLng(
      math.cos(20 * math.pi / 180),
      math.sin(20 * math.pi / 180),
    );
    final upright = projectStrike(
      user: user,
      strike: strike,
      deviceToWorld: levelMatrix(0),
      horizontalFovDeg: fov,
      verticalFovDeg: fov,
      screenSize: size,
    )!;
    // Roll 90° about the camera axis (body-frame rotation → post-multiply).
    final rolled = projectStrike(
      user: user,
      strike: strike,
      deviceToWorld: matmul(levelMatrix(0), rotZ(math.pi / 2)),
      horizontalFovDeg: fov,
      verticalFovDeg: fov,
      screenSize: size,
    )!;

    double radius(p) =>
        math.sqrt(math.pow(p.position.dx - 500, 2) + math.pow(p.position.dy - 500, 2));

    expect(rolled.onScreen, isTrue);
    // Distance from center is preserved by a roll about the optical axis.
    expect(radius(rolled), closeTo(radius(upright), 2));
    // Upright it's mostly horizontal; rolled 90° it's mostly vertical.
    expect((upright.position.dx - 500).abs(), greaterThan((upright.position.dy - 500).abs()));
    expect((rolled.position.dy - 500).abs(), greaterThan((rolled.position.dx - 500).abs()));
  });

  test('malformed matrix returns null', () {
    final p = projectStrike(
      user: user,
      strike: north,
      deviceToWorld: const [1, 0, 0], // wrong length
      horizontalFovDeg: fov,
      verticalFovDeg: fov,
      screenSize: size,
    );
    expect(p, isNull);
  });
}
