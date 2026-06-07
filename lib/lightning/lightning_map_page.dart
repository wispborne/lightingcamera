import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/utils/logging.dart';

/// Fallback center (geographic center of the contiguous US) when location is denied.
const LatLng _fallbackCenter = LatLng(39.8283, -98.5795);

class LightningMapPage extends StatefulWidget {
  const LightningMapPage({super.key});

  @override
  State<LightningMapPage> createState() => _LightningMapPageState();
}

class _LightningMapPageState extends State<LightningMapPage> {
  final MapController _mapController = MapController();
  LatLng? _userLocation;
  String? _statusMessage;

  // Drives a smooth per-second re-render so markers fade as they age.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _init();
  }

  Future<void> _init() async {
    final center = await _resolveLocation();
    if (!mounted) return;
    setState(() => _userLocation = center);
    _mapController.move(center, 7);
    lightningService.connect(center);
  }

  /// Resolve the user's position, falling back to a default center on denial.
  Future<LatLng> _resolveLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _statusMessage = 'Location off — showing a default area.';
        return _fallbackCenter;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _statusMessage = 'Location denied — showing a default area.';
        return _fallbackCenter;
      }
      final pos = await Geolocator.getCurrentPosition();
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      Fimber.e('Location lookup failed: $e');
      _statusMessage = 'Could not get location — showing a default area.';
      return _fallbackCenter;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    lightningService.disconnect();
    _mapController.dispose();
    super.dispose();
  }

  /// Opacity falls off linearly with age across the display window.
  double _opacityForAge(DateTime time) {
    final age = DateTime.now().difference(time);
    final fraction = 1 - age.inMilliseconds / LightningService.displayWindow.inMilliseconds;
    return fraction.clamp(0.05, 1.0);
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    if (_userLocation != null) {
      markers.add(Marker(
        point: _userLocation!,
        width: 20,
        height: 20,
        child: const Icon(Icons.my_location, color: Colors.lightBlueAccent, size: 20),
      ));
    }

    for (final strike in lightningService.strikes.value) {
      markers.add(Marker(
        point: strike.position,
        width: 18,
        height: 18,
        child: Opacity(
          opacity: _opacityForAge(strike.time),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.amber.withValues(alpha: 0.9),
              boxShadow: [
                BoxShadow(
                  color: Colors.amber.withValues(alpha: 0.6),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      ));
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final strikeCount = lightningService.strikes.value.length;
    final connected = lightningService.connected.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lightning Map'),
        backgroundColor: Colors.black.withValues(alpha: 0.6),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _userLocation ?? _fallbackCenter,
              initialZoom: 7,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.wisp.lightingcamera',
              ),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    connected ? Icons.bolt : Icons.bolt_outlined,
                    color: connected ? Colors.amber : Colors.white54,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    connected
                        ? '$strikeCount strikes nearby'
                        : 'Connecting…',
                    style: const TextStyle(color: Colors.white),
                  ),
                  if (_statusMessage != null) ...[
                    const Spacer(),
                    Flexible(
                      child: Text(
                        _statusMessage!,
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: Colors.orange, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
