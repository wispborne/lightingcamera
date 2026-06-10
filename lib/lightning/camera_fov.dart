import 'package:flutter/services.dart';

import 'package:lightingcamera/utils/logging.dart';

/// Reads the back camera's horizontal field of view from the platform.
///
/// The `camera` plugin doesn't expose FOV, so this goes through a small method
/// channel (see `MainActivity.kt`) that reads it from Camera2. If the platform
/// can't supply it, we fall back to [defaultHorizontalFovDegrees] so the overlay
/// still works, just slightly less precisely.
class CameraFov {
  static const _channel = MethodChannel('com.wisp.lightingcamera/camera_info');

  /// A typical phone main-camera horizontal FOV, used when the query fails.
  static const double defaultHorizontalFovDegrees = 65.0;

  /// Horizontal FOV in degrees for the back camera. Never throws — returns the
  /// default on any failure.
  static Future<double> horizontalFovDegrees() async {
    try {
      final value = await _channel.invokeMethod<double>('getHorizontalFov');
      if (value != null && value > 1 && value < 179) {
        return value;
      }
    } catch (e) {
      Fimber.w('Camera FOV query failed, using default: $e');
    }
    return defaultHorizontalFovDegrees;
  }
}
