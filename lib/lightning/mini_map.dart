import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:signals/signals_flutter.dart';

import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/lightning/mini_map_controller.dart';
import 'package:lightingcamera/settings/settings_manager.dart';

/// A small, non-interactive lightning map shown in the top-left of the camera
/// page. Centred on the user, it plots recent strikes the same way the full map
/// does, at the opacity chosen in settings.
///
/// Renders nothing until [MiniMapController] has a location fix. The parent is
/// responsible for only mounting this when the mini map setting is on.
class MiniMap extends StatefulWidget {
  const MiniMap({super.key, required this.controller});

  final MiniMapController controller;

  /// Thumbnail edge length in logical pixels (multiple of the 8dp grid).
  static const double size = 120;

  @override
  State<MiniMap> createState() => _MiniMapState();
}

class _MiniMapState extends State<MiniMap> {
  final MapController _mapController = MapController();

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Color _colorForAge(DateTime time) {
    final fraction =
        (DateTime.now().difference(time).inMilliseconds /
                LightningService.displayWindow.inMilliseconds)
            .clamp(0.0, 1.0);
    final hue = 240 * (1 - fraction);
    return HSVColor.fromAHSV(1, hue, 1, 1).toColor();
  }

  double _opacityForAge(DateTime time) {
    final fraction =
        1 -
        DateTime.now().difference(time).inMilliseconds /
            LightningService.displayWindow.inMilliseconds;
    return fraction.clamp(0.1, 1.0);
  }

  List<Marker> _buildMarkers(LatLng user, ColorScheme colors) {
    final markers = <Marker>[
      Marker(
        point: user,
        width: 16,
        height: 16,
        child: Icon(Icons.my_location, color: colors.primary, size: 16),
      ),
    ];

    for (final strike in lightningService.strikes.value) {
      final color = _colorForAge(strike.time);
      markers.add(
        Marker(
          point: strike.position,
          width: 10,
          height: 10,
          child: Opacity(
            opacity: _opacityForAge(strike.time),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Watch((context) {
      final center = widget.controller.userLocation.value;
      final opacity = settingsManager.miniMapOpacitySignal.value;

      final content = center == null
          ? ColoredBox(
              color: colors.surface,
              child: const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 7,
                // Static thumbnail: no panning, zooming, or rotation.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.wisp.lightingcamera',
                ),
                Watch(
                  (context) =>
                      MarkerLayer(markers: _buildMarkers(center, colors)),
                ),
              ],
            );

      return Opacity(
        opacity: opacity,
        child: SizedBox(
          width: MiniMap.size,
          height: MiniMap.size,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: content,
          ),
        ),
      );
    });
  }
}
