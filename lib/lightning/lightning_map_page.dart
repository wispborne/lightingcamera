import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

const LatLng _fallbackCenter = LatLng(39.8283, -98.5795);
const double _speedOfSoundMps = 343;
const double _thunderMaxRadiusMeters = 15 * 1609.344; // 15 miles

/// Zoom the map opens at, centered on the user — a regional view (~tens of km
/// across) rather than the whole multi-state radius the relay covers.
const double _defaultZoom = 9;

class LightningMapPage extends StatefulWidget {
  const LightningMapPage({super.key});

  @override
  State<LightningMapPage> createState() => _LightningMapPageState();
}

class _LightningMapPageState extends State<LightningMapPage> {
  final MapController _mapController = MapController();
  LatLng? _userLocation;
  String? _statusMessage;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Reuse the location the camera page already resolved, if any, so the map
    // opens in the right place on the first frame instead of at the fallback.
    _userLocation = lightningService.lastCenter;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _init();
  }

  Future<void> _init() async {
    // If the camera page already resolved a location, the map is centered on it
    // via initialCenter (seeded in initState) — just open the relay connection.
    final known = lightningService.lastCenter;
    if (known != null) {
      lightningService.acquire(known);
      return;
    }

    // Otherwise ask for a fresh fix. By the time it arrives the map has rendered
    // at least once, so it's safe to recenter via the controller.
    final center = await _resolveLocation();
    if (!mounted) return;
    setState(() => _userLocation = center);
    _mapController.move(center, _defaultZoom);
    lightningService.acquire(center);
  }

  Future<LatLng> _resolveLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _statusMessage = 'Location off — showing default area';
        return _fallbackCenter;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _statusMessage = 'Location denied — showing default area';
        return _fallbackCenter;
      }
      final pos = await Geolocator.getCurrentPosition();
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      Fimber.e('Location lookup failed: $e');
      _statusMessage = 'Could not get location';
      return _fallbackCenter;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    lightningService.release();
    _mapController.dispose();
    super.dispose();
  }

  double _opacityForAge(DateTime time) {
    final age = DateTime.now().difference(time);
    final fraction =
        1 - age.inMilliseconds / LightningService.displayWindow.inMilliseconds;
    return fraction.clamp(0.05, 1.0);
  }

  Color _colorForAge(DateTime time) {
    final age = DateTime.now().difference(time);
    final fraction =
        (age.inMilliseconds / LightningService.displayWindow.inMilliseconds)
            .clamp(0.0, 1.0);
    final hue = 240 * (1 - fraction);
    return HSVColor.fromAHSV(1, hue, 1, 1).toColor();
  }

  List<Marker> _buildMarkers() {
    final colors = Theme.of(context).colorScheme;
    final markers = <Marker>[];

    if (_userLocation != null) {
      markers.add(
        Marker(
          point: _userLocation!,
          width: 24,
          height: 24,
          child: Icon(Icons.my_location, color: colors.primary, size: 24),
        ),
      );
    }

    for (final strike in lightningService.strikes.value) {
      final color = _colorForAge(strike.time);
      markers.add(
        Marker(
          point: strike.position,
          width: 16,
          height: 16,
          child: Opacity(
            opacity: _opacityForAge(strike.time),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.9),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.6),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  List<CircleMarker> _buildThunderCircles() {
    final colors = Theme.of(context).colorScheme;
    final circles = <CircleMarker>[];
    final now = DateTime.now();

    for (final strike in lightningService.strikes.value) {
      final elapsedSeconds = now.difference(strike.time).inMilliseconds / 1000;
      final radius = _speedOfSoundMps * elapsedSeconds;
      if (radius <= 0 || radius > _thunderMaxRadiusMeters) continue;

      final fade = (1 - radius / _thunderMaxRadiusMeters).clamp(0.0, 1.0);
      circles.add(
        CircleMarker(
          point: strike.position,
          radius: radius,
          useRadiusInMeter: true,
          color: Colors.transparent,
          borderColor: colors.primary.withValues(alpha: fade),
          borderStrokeWidth: 2,
        ),
      );
    }
    return circles;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final strikeCount = lightningService.strikes.value.length;
    final connected = lightningService.connected.value;
    final showThunder = settingsManager.showThunderCircles;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    // Without a key the relay won't connect; nudge the user to Settings rather
    // than showing a bare "Disconnected". Test mode needs no key, so skip it then.
    final noKey =
        !settingsManager.lightningTestMode && settingsManager.relayKey.isEmpty;

    // Explicit relay (API) connection status. Test mode feeds simulated strikes
    // rather than the relay, so flag that distinctly instead of "Connected".
    final (
      String statusLabel,
      Color statusColor,
      IconData statusIcon,
    ) = settingsManager.lightningTestMode
        ? ('Simulated (test mode)', colors.tertiary, Icons.science_outlined)
        : noKey
        ? ('No relay key', colors.onSurfaceVariant, Icons.key_off_outlined)
        : connected
        ? ('Connected', colors.primary, Icons.cloud_done_outlined)
        : ('Disconnected', colors.error, Icons.cloud_off_outlined);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text('Lightning Map', style: text.titleLarge),
        backgroundColor: colors.surface.withValues(alpha: 0.8),
        actions: [
          IconButton(
            tooltip: showThunder
                ? 'Hide thunder circles'
                : 'Show thunder circles',
            icon: Icon(
              showThunder ? Symbols.spatial_audio : Symbols.spatial_audio,
              color: showThunder ? colors.primary : colors.onSurfaceVariant,
            ),
            onPressed: () async {
              await settingsManager.setShowThunderCircles(!showThunder);
              setState(() {});
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _userLocation ?? _fallbackCenter,
              initialZoom: _defaultZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.wisp.lightingcamera',
              ),
              if (showThunder) CircleLayer(circles: _buildThunderCircles()),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          Positioned(
            bottom: bottomInset + 16,
            left: 16,
            right: 16,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(statusIcon, color: statusColor, size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            statusLabel,
                            style: text.bodyMedium?.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            noKey
                                ? 'Enter your relay key in Settings to see '
                                      'live strikes.'
                                : _statusMessage ??
                                      (connected
                                          ? '$strikeCount strikes nearby'
                                          : 'No strikes yet'),
                            style: text.bodySmall?.copyWith(
                              color: _statusMessage != null && !noKey
                                  ? colors.error
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
