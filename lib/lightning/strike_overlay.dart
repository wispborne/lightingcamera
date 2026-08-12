import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:signals/signals_flutter.dart';

import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/lightning/strike_overlay_controller.dart';
import 'package:lightingcamera/lightning/strike_projection.dart';
import 'package:lightingcamera/sensors/orientation_service.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/units.dart';

/// Transparent layer drawn over the camera feed showing the most recent strikes
/// anchored to their real-world direction. In-view strikes appear as glowing
/// markers; out-of-view strikes appear as edge arrows pointing the way to turn.
///
/// Hides itself entirely when the overlay setting is off, or when location or
/// orientation data isn't available, so the camera is never affected.
class StrikeOverlay extends StatelessWidget {
  const StrikeOverlay({
    super.key,
    required this.controller,
    required this.previewAspectRatio,
  });

  final StrikeOverlayController controller;

  /// The on-screen camera frame's width-over-height. The camera image is shown
  /// with `BoxFit.contain`, so it sits in a centered rectangle of this shape
  /// (with letterbox bars filling the rest). Markers are placed within that
  /// rectangle so they line up with the visible image.
  final double previewAspectRatio;

  /// How many of the most recent strikes to show.
  static const int _maxStrikes = 5;

  /// Marker diameter and edge-arrow box size in logical pixels.
  static const double _markerSize = 20;
  static const double _arrowSize = 32;

  static const _cardinals = [
    (label: 'N', bearing: 0.0),
    (label: 'E', bearing: 90.0),
    (label: 'S', bearing: 180.0),
    (label: 'W', bearing: 270.0),
  ];

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      if (!settingsManager.strikeOverlayEnabledSignal.value) {
        return const SizedBox.shrink();
      }

      final matrix = orientationService.rotationMatrix.value;
      final user = controller.userLocation.value;
      if (matrix == null || user == null) {
        return const SizedBox.shrink();
      }

      final hFov = controller.horizontalFovDeg.value;
      final colors = Theme.of(context).colorScheme;
      final text = Theme.of(context).textTheme;

      final accuracyRad = orientationService.accuracyRad.value;
      final suppressedUntil =
          settingsManager.calibrationSuppressedUntilSignal.value;
      final calibrationSuppressed =
          suppressedUntil != null && DateTime.now().isBefore(suppressedUntil);
      final poorAccuracy =
          accuracyRad >= 0 &&
          accuracyRad > OrientationService.poorAccuracyThreshold &&
          !calibrationSuppressed;
      // Fimber.i("Accuracy: ${accuracyRad}");

      // Within range and newest first, capped at five. Distant strikes are
      // dropped entirely — no marker and no edge arrow.
      final maxDistanceKm = settingsManager.maxStrikeDistanceKmSignal.value;
      final strikes =
          lightningService.strikes.value
              .where(
                (s) =>
                    _distance.as(LengthUnit.Kilometer, user, s.position) <=
                    maxDistanceKm,
              )
              .toList()
            ..sort((a, b) => b.time.compareTo(a.time));
      final recent = strikes.take(_maxStrikes).toList();

      final unitSystem = settingsManager.unitSystemSignal.value;

      return LayoutBuilder(
        builder: (context, constraints) {
          final screen = constraints.biggest;
          if (screen.isEmpty) return const SizedBox.shrink();

          // The camera image is letterboxed (BoxFit.contain), so it fills only a
          // centered rectangle of the screen at its own aspect ratio. Project
          // into that rectangle so markers track the visible frame, not the
          // black bars.
          final screenAspect = screen.width / screen.height;
          final double rectW, rectH;
          if (previewAspectRatio > screenAspect) {
            rectW = screen.width;
            rectH = screen.width / previewAspectRatio;
          } else {
            rectH = screen.height;
            rectW = screen.height * previewAspectRatio;
          }
          final originX = (screen.width - rectW) / 2;
          final originY = (screen.height - rectH) / 2;
          final size = Size(rectW, rectH);

          // The platform reports the FOV along the sensor's long side at 1.0×
          // zoom. On screen that side runs along the preview rectangle's LONG
          // side — in portrait that's the vertical axis, not the width. Anchor
          // the projection there, narrow it by the current zoom, and derive the
          // short side from the rectangle's shape.
          final zoom = controller.zoom.value;
          final halfTanLong = math.tan(hFov * math.pi / 180 / 2) / zoom;
          final longSide = math.max(size.width, size.height);
          final shortSide = math.min(size.width, size.height);
          final fovLong = 2 * math.atan(halfTanLong) * 180 / math.pi;
          final fovShort =
              2 * math.atan(halfTanLong * shortSide / longSide) * 180 / math.pi;
          final isLandscape = size.width >= size.height;
          final hFovOnScreen = isLandscape ? fovLong : fovShort;
          final vFovOnScreen = isLandscape ? fovShort : fovLong;

          final children = <Widget>[];

          for (final c in _cardinals) {
            final placement = projectBearing(
              bearingDeg: c.bearing,
              deviceToWorld: matrix,
              horizontalFovDeg: hFovOnScreen,
              verticalFovDeg: vFovOnScreen,
              screenSize: size,
            );
            if (placement != null) {
              children.add(
                _cardinalLabel(
                  placement.position,
                  placement.onScreen,
                  c.label,
                  colors,
                  size,
                ),
              );
            }
          }

          final showInfo = settingsManager.showStrikeInfoSignal.value;

          for (final strike in recent) {
            final placement = projectStrike(
              user: user,
              strike: strike.position,
              deviceToWorld: matrix,
              horizontalFovDeg: hFovOnScreen,
              verticalFovDeg: vFovOnScreen,
              screenSize: size,
            );
            if (placement == null) continue;

            final color = _colorForAge(strike.time);
            final opacity = _opacityForAge(strike.time);

            if (placement.onScreen) {
              children.add(_marker(placement.position, color, opacity));
              if (showInfo) {
                children.add(
                  _infoLabel(
                    placement.position,
                    user,
                    strike,
                    opacity,
                    colors,
                    size,
                    unitSystem,
                  ),
                );
              }
            } else {
              children.add(
                _arrow(
                  placement.position,
                  placement.angleRadians,
                  color,
                  opacity,
                  colors,
                  size,
                ),
              );
            }
          }

          // The markers, arrows, and labels never take pointers so camera
          // gestures pass through. They're positioned relative to the camera
          // frame's rectangle (offset from the screen edge by the letterbox
          // bars). The calibration banner sits outside the IgnorePointer, on the
          // full screen, so its "Mute" button stays tappable.
          return Stack(
            children: [
              Positioned(
                left: originX,
                top: originY,
                width: rectW,
                height: rectH,
                child: IgnorePointer(
                  child: Stack(clipBehavior: Clip.none, children: children),
                ),
              ),
              if (poorAccuracy) _calibrationBanner(colors, text),
            ],
          );
        },
      );
    });
  }

  Widget _marker(Offset center, Color color, double opacity) {
    return Positioned(
      left: center.dx - _markerSize / 2,
      top: center.dy - _markerSize / 2,
      child: Opacity(
        opacity: opacity,
        child: Container(
          width: _markerSize,
          height: _markerSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.9),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.6),
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Speed of sound in m/s at ~20 °C.
  static const double _speedOfSound = 343;

  static const Distance _distance = Distance();

  Widget _infoLabel(
    Offset markerCenter,
    LatLng user,
    Strike strike,
    double opacity,
    ColorScheme colors,
    Size viewSize,
    UnitSystem unitSystem,
  ) {
    final distKm = _distance.as(LengthUnit.Kilometer, user, strike.position);
    final distText = formatDistanceKm(distKm, unitSystem);

    final thunderDelaySec = distKm * 1000 / _speedOfSound;
    final ageSec = DateTime.now().difference(strike.time).inMilliseconds / 1000;
    final remaining = thunderDelaySec - ageSec;
    final thunderText = remaining > 0
        ? 'thunder in ${remaining.round()}s'
        : 'thunder ${(-remaining).round()}s ago';

    // Position the label just below the marker, clamped so it stays visible.
    const labelHeight = 32.0;
    const labelMaxWidth = 160.0;
    final left = (markerCenter.dx - labelMaxWidth / 2).clamp(
      4.0,
      viewSize.width - labelMaxWidth - 4,
    );
    final top = (markerCenter.dy + _markerSize / 2 + 4).clamp(
      4.0,
      viewSize.height - labelHeight - 4,
    );

    return Positioned(
      left: left,
      top: top,
      child: Opacity(
        opacity: opacity,
        child: Container(
          constraints: const BoxConstraints(maxWidth: labelMaxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '$distText · $thunderText',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: colors.onSurface,
              shadows: [Shadow(color: colors.surface, blurRadius: 4)],
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrow(
    Offset edge,
    double angle,
    Color color,
    double opacity,
    ColorScheme colors,
    Size size,
  ) {
    // Pull the arrow slightly inward from the very edge so it isn't clipped.
    const inset = _arrowSize / 2 + 4;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final dx = edge.dx - cx;
    final dy = edge.dy - cy;
    final len = math.sqrt(dx * dx + dy * dy);
    final ix = len == 0 ? edge.dx : edge.dx - dx / len * inset;
    final iy = len == 0 ? edge.dy : edge.dy - dy / len * inset;

    return Positioned(
      left: ix - _arrowSize / 2,
      top: iy - _arrowSize / 2,
      child: Opacity(
        opacity: opacity,
        child: Transform.rotate(
          // Icons.arrow_forward points right (0 rad), matching angleRadians.
          angle: angle,
          child: Icon(
            Icons.arrow_forward,
            size: _arrowSize,
            color: color,
            shadows: [
              Shadow(
                color: colors.surface.withValues(alpha: 0.8),
                blurRadius: 6,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardinalLabel(
    Offset position,
    bool onScreen,
    String label,
    ColorScheme colors,
    Size size,
  ) {
    // Clamp to keep the label fully visible inside the viewport.
    const labelSize = 24.0;
    const inset = 8.0;
    final x = position.dx.clamp(inset, size.width - labelSize - inset);
    final y = position.dy.clamp(inset, size.height - labelSize - inset);

    return Positioned(
      left: x - labelSize / 2,
      top: y - labelSize / 2,
      child: Opacity(
        opacity: onScreen ? 0.9 : 0.5,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: colors.onSurface,
            shadows: [
              Shadow(color: colors.surface, blurRadius: 6),
              Shadow(color: colors.surface, blurRadius: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _calibrationBanner(ColorScheme colors, TextTheme text) {
    // Sit above the exposure slider (bottom: 140, ~180 tall) so the "Mute 4h"
    // button on the right isn't covered and stays tappable.
    return Positioned(
      bottom: 336,
      left: 16,
      right: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.errorContainer.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.explore_off, size: 20, color: colors.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Compass inaccurate — wave phone in a figure-8',
                  style: text.bodySmall?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: settingsManager.suppressCalibrationWarning,
                style: TextButton.styleFrom(
                  foregroundColor: colors.onErrorContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Mute 4h'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Age styling mirrors the lightning map: fresh strikes are blue/opaque, older
  // ones shift toward red and fade out over the service's display window.
  double _opacityForAge(DateTime time) {
    final age = DateTime.now().difference(time);
    final fraction =
        1 - age.inMilliseconds / LightningService.displayWindow.inMilliseconds;
    return fraction.clamp(0.15, 1.0);
  }

  // Hue encodes strike age (blue = fresh → red = old) and must stay legible
  // over arbitrary camera frames, so it is intentionally not theme-colored.
  Color _colorForAge(DateTime time) {
    final age = DateTime.now().difference(time);
    final fraction =
        (age.inMilliseconds / LightningService.displayWindow.inMilliseconds)
            .clamp(0.0, 1.0);
    final hue = 240 * (1 - fraction);
    return HSVColor.fromAHSV(1, hue, 1, 1).toColor();
  }
}
