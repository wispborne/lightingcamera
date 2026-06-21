import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:signals/signals_flutter.dart';

import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/lightning/rain_radar_service.dart';
import 'package:lightingcamera/main.dart';
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
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    // Reuse the location the camera page already resolved this session, or the
    // last one we persisted, so the map opens in the right place on the first
    // frame instead of at the fallback — even on a cold start from a
    // notification, before any fresh GPS fix arrives.
    _userLocation = lightningService.lastCenter ?? _cachedCenter();
    rainRadarService.acquire();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _init();
  }

  Future<void> _init() async {
    // If we already have a location for this session or a cached one from a
    // previous run, the map is centered on it via initialCenter (seeded in
    // initState) — just open the relay connection there. The relay's own
    // location stream and the recenter button refine it from here.
    final known = lightningService.lastCenter ?? _cachedCenter();
    if (known != null) {
      lightningService.acquire(known);
      return;
    }

    // Otherwise ask for a fresh fix. By the time it arrives the map has rendered
    // at least once, so it's safe to recenter via the controller.
    final resolved = await _resolveLocation();
    if (!mounted) return;
    final center = resolved ?? _fallbackCenter;
    setState(() => _userLocation = center);
    _mapController.move(center, _defaultZoom);
    lightningService.acquire(center);
  }

  /// The last map center we persisted, or null if the map has never resolved a
  /// location before. Used to open on the user's last known area on a cold
  /// start, before any fresh GPS fix is available.
  LatLng? _cachedCenter() {
    final lat = settingsManager.lastMapLatitude;
    final lon = settingsManager.lastMapLongitude;
    if (lat == null || lon == null) return null;
    return LatLng(lat, lon);
  }

  /// Returns the user's position, or null if it couldn't be resolved (with
  /// [_statusMessage] set to say why).
  Future<LatLng?> _resolveLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _statusMessage = 'Location off — showing default area';
        return null;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _statusMessage = 'Location denied — showing default area';
        return null;
      }
      final pos = await Geolocator.getCurrentPosition();
      _statusMessage = null;
      return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      Fimber.e('Location lookup failed: $e');
      _statusMessage = 'Could not get location';
      return null;
    }
  }

  /// Re-resolve the user's location, recenter the map on it, and shift the
  /// lightning feed's subscription area to match. Keeps the current zoom.
  Future<void> _recenterOnUser() async {
    if (_locating) return;
    setState(() => _locating = true);
    final resolved = await _resolveLocation();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (resolved != null) _userLocation = resolved;
    });
    if (resolved == null) return;
    _mapController.move(resolved, _mapController.camera.zoom);
    lightningService.updateCenter(resolved);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    lightningService.release();
    rainRadarService.release();
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
    // Advance every ring by the user's lead so it reaches them as early as the
    // real thunder does (see SettingsManager.thunderLeadSeconds).
    final lead = settingsManager.thunderLeadSeconds;

    for (final strike in lightningService.strikes.value) {
      // Each ring also advances by the strike's own upstream delay, on top of
      // the shared manual lead.
      final elapsedSeconds =
          now.difference(strike.time).inMilliseconds / 1000 +
          lead +
          strike.delaySeconds;
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

  /// A small sheet to tune how far ahead the thunder rings run, so the ring
  /// reaches the user when the thunder actually does (see
  /// SettingsManager.thunderLeadSeconds).
  void _showThunderTimingSheet() {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        var pending = settingsManager.thunderLeadSeconds;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: StatefulBuilder(
              builder: (context, setSheetState) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Text('Thunder timing', style: text.titleMedium),
                    Text(
                      'Thunder usually arrives a little before the ring reaches '
                      'you, because a bolt is a long channel whose nearest point '
                      'is closer than the plotted strike. Nudge the rings outward '
                      'to match what you hear.',
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      pending == 0 ? 'No lead' : 'Lead ${pending.round()} s',
                      style: text.bodyMedium,
                    ),
                    Slider(
                      value: pending,
                      max: SettingsManager.maxThunderLeadSeconds,
                      divisions: SettingsManager.maxThunderLeadSeconds.round(),
                      label: '${pending.round()} s',
                      onChanged: (v) => setSheetState(() => pending = v),
                      onChangeEnd: (v) async {
                        await settingsManager.setThunderLeadSeconds(v);
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final strikeCount = lightningService.strikes.value.length;
    final connected = lightningService.connected.value;
    final showThunder = settingsManager.showThunderCircles;
    final showRadar = settingsManager.rainRadarEnabled;
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
            tooltip: showRadar ? 'Hide rain radar' : 'Show rain radar',
            icon: Icon(
              Symbols.rainy,
              color: showRadar
                  ? colors.primary
                  : colors.onSurfaceVariant.withAlpha(150),
            ),
            onPressed: () async {
              await settingsManager.setRainRadarEnabled(!showRadar);
              setState(() {});
            },
          ),
          IconButton(
            tooltip: showThunder
                ? 'Hide thunder circles'
                : 'Show thunder circles',
            icon: Icon(
              showThunder ? Symbols.lightning_stand : Symbols.lightning_stand,
              color: showThunder ? colors.primary : colors.onSurfaceVariant.withAlpha(150),
            ),
            onPressed: () async {
              await settingsManager.setShowThunderCircles(!showThunder);
              setState(() {});
            },
          ),
          if (showThunder)
            IconButton(
              tooltip: 'Adjust thunder timing',
              icon: Icon(Symbols.tune, color: colors.onSurfaceVariant),
              onPressed: _showThunderTimingSheet,
            ),
          IconButton(
            tooltip: 'Settings',
            icon: Icon(Icons.settings_outlined, color: colors.onSurfaceVariant),
            onPressed: () => context.pushNamed(Pages.settings),
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
              // Rain radar sits above the base map but below the strikes, so the
              // lightning markers stay crisp on top. Hidden (null template) when
              // the setting is off or no fresh frame is available.
              SignalBuilder(
                builder: (context) {
                  final template = rainRadarService.tileUrlTemplate.value;
                  if (template == null) return const SizedBox.shrink();
                  return Opacity(
                    opacity: 0.7,
                    child: TileLayer(
                      urlTemplate: template,
                      userAgentPackageName: 'com.wisp.lightingcamera',
                      // RainViewer caps radar tiles here; upscale for closer
                      // views rather than fetching its error placeholder.
                      maxNativeZoom: RainRadarService.maxNativeZoom,
                    ),
                  );
                },
              ),
              if (showThunder) CircleLayer(circles: _buildThunderCircles()),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          Positioned(
            bottom: bottomInset + 96,
            right: 16,
            child: FloatingActionButton(
              tooltip: 'Center on my location',
              onPressed: _recenterOnUser,
              child: _locating
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onPrimaryContainer,
                      ),
                    )
                  : const Icon(Icons.my_location),
            ),
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
                    // Required RainViewer attribution — only while a radar frame
                    // is actually on screen.
                    SignalBuilder(
                      builder: (context) {
                        if (rainRadarService.tileUrlTemplate.value == null) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            'Radar © RainViewer',
                            style: text.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        );
                      },
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
