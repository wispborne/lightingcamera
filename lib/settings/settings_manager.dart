import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import 'package:lightingcamera/utils/units.dart';

final settingsManager = SettingsManager();

/// Shape of the frames the camera captures.
///
/// [wide16x9] is the default 16:9 stream — sharper, but trims the top and
/// bottom of the sensor. [full4x3] uses the sensor's native 4:3 shape for a
/// taller field of view (matching the stock camera's photo mode), at the cost
/// of a little resolution.
enum CaptureAspect { wide16x9, full4x3 }

class SettingsManager {
  /// Legacy key holding a single shutter offset for every orientation. Kept so
  /// existing installs migrate their old position into the new per-orientation
  /// map on first launch.
  static const _shutterOffsetXKey = 'shutter_offset_x';
  static const _lightningTestModeKey = 'lightning_test_mode';
  static const _showThunderCirclesKey = 'show_thunder_circles';
  static const _thunderLeadSecondsKey = 'thunder_lead_seconds';
  static const _strikeOverlayEnabledKey = 'strike_overlay_enabled';
  static const _showStrikeInfoKey = 'show_strike_info';
  static const _miniMapEnabledKey = 'mini_map_enabled';
  static const _miniMapOpacityKey = 'mini_map_opacity';
  static const _rainRadarEnabledKey = 'rain_radar_enabled';
  static const _customRelayUrlKey = 'custom_relay_url';
  static const _relayKeyKey = 'relay_key';
  static const _recentRelayUrlsKey = 'recent_relay_urls';

  /// How many recent relay URLs we remember for the field's suggestion dropdown.
  static const _maxRecentRelayUrls = 5;
  static const _cacheInfoCollapsedKey = 'cache_info_collapsed';
  static const _calibrationSuppressedUntilKey = 'calibration_suppressed_until';
  static const _skipGalleryExitWarningKey = 'skip_gallery_exit_warning';
  static const _captureAspectKey = 'capture_aspect';
  static const _cameraZoomKey = 'camera_zoom';
  static const _unitSystemKey = 'unit_system';
  static const _maxStrikeDistanceKmKey = 'max_strike_distance_km';
  static const _lightningThresholdKey = 'lightning_confidence_threshold';
  static const _geotagPhotosKey = 'geotag_photos';
  static const _galleryCrossAxisCountKey = 'gallery_cross_axis_count';
  static const _lightningAlertsEnabledKey = 'lightning_alerts_enabled';
  static const _alertRadiusKmKey = 'alert_radius_km';
  static const _alertCooldownMinutesKey = 'alert_cooldown_minutes';
  static const _lastMapLatKey = 'last_map_lat';
  static const _lastMapLonKey = 'last_map_lon';

  /// Default radius for proximity alerts, in kilometres. Bounded by the same
  /// [minStrikeDistanceKm]/[maxStrikeDistanceKm] range the overlay filter uses.
  static const double defaultAlertRadiusKm = 15;

  /// Bounds for the quiet period between proximity alerts, in minutes.
  static const double minAlertCooldownMinutes = 1;
  static const double maxAlertCooldownMinutes = 30;
  static const double defaultAlertCooldownMinutes = 2;

  /// Bounds for the overlay's maximum strike distance, in kilometres.
  static const double minStrikeDistanceKm = 5;
  static const double maxStrikeDistanceKm = 100;

  /// Bounds for the gallery's lightning-detection confidence threshold (0–1).
  /// The classifier's own confidence floor is pinned at or below the minimum so
  /// the whole slider range has data to filter against.
  static const double minLightningThreshold = 0.10;
  static const double maxLightningThreshold = 0.90;

  /// Position of the shutter button as a fraction of its travel region —
  /// (0, 0) is the top-left, (1, 1) the bottom-right. Stored separately for each
  /// phone orientation so the button stays where the user put it in portrait
  /// without dragging it back when they rotate.
  late final Signal<Map<DeviceOrientation, Offset>> _shutterOffsets;
  ReadonlySignal<Map<DeviceOrientation, Offset>> get shutterOffsetsSignal =>
      _shutterOffsets;

  /// Where the shutter button sits before the user moves it: centred
  /// horizontally, near the bottom of the screen (its old fixed home).
  static const defaultShutterOffset = Offset(0.5, 0.92);

  /// The saved shutter position for [orientation], or [defaultShutterOffset] if
  /// the user has never positioned the button in that orientation.
  Offset shutterOffsetFor(DeviceOrientation orientation) =>
      _shutterOffsets.value[orientation] ?? defaultShutterOffset;

  String _shutterOffsetXKeyFor(DeviceOrientation orientation) =>
      'shutter_offset_x_${orientation.name}';
  String _shutterOffsetYKeyFor(DeviceOrientation orientation) =>
      'shutter_offset_y_${orientation.name}';

  late final Signal<bool> _isRepositioning;
  ReadonlySignal<bool> get isRepositioningSignal => _isRepositioning;
  bool get isRepositioning => _isRepositioning.value;

  /// When on, the lightning map simulates strikes instead of connecting to the
  /// relay (handy for testing the map without a live relay or a storm).
  late final Signal<bool> _lightningTestMode;
  ReadonlySignal<bool> get lightningTestModeSignal => _lightningTestMode;
  bool get lightningTestMode => _lightningTestMode.value;

  /// When on, the map draws expanding rings showing where the sound of each
  /// strike's thunder has travelled. On by default.
  late final Signal<bool> _showThunderCircles;
  ReadonlySignal<bool> get showThunderCirclesSignal => _showThunderCircles;
  bool get showThunderCircles => _showThunderCircles.value;

  /// Seconds to advance the thunder rings, compensating for thunder arriving
  /// earlier than a point-source circle predicts: real flashes are kilometres-
  /// long channels, so the nearest part of the bolt — and the thunder you hear
  /// first — is closer than Blitzortung's single located point. Added to each
  /// ring's elapsed time so the ring reaches you a touch sooner. 0 = no lead.
  static const double maxThunderLeadSeconds = 30;
  late final Signal<double> _thunderLeadSeconds;
  ReadonlySignal<double> get thunderLeadSecondsSignal => _thunderLeadSeconds;
  double get thunderLeadSeconds => _thunderLeadSeconds.value;

  /// When on, the camera page overlays recent strikes on the live feed, anchored
  /// to their real-world direction. Off by default — it needs location and
  /// compass access and draws extra battery.
  late final Signal<bool> _strikeOverlayEnabled;
  ReadonlySignal<bool> get strikeOverlayEnabledSignal => _strikeOverlayEnabled;
  bool get strikeOverlayEnabled => _strikeOverlayEnabled.value;

  /// When on, each on-screen strike marker shows distance and thunder arrival
  /// time. Only visible when the strike overlay itself is enabled.
  late final Signal<bool> _showStrikeInfo;
  ReadonlySignal<bool> get showStrikeInfoSignal => _showStrikeInfo;
  bool get showStrikeInfo => _showStrikeInfo.value;

  /// When on, a thumbnail lightning map sits in the top-left of the camera page.
  /// Off by default — it needs location and draws extra battery.
  late final Signal<bool> _miniMapEnabled;
  ReadonlySignal<bool> get miniMapEnabledSignal => _miniMapEnabled;
  bool get miniMapEnabled => _miniMapEnabled.value;

  /// Opacity of the camera-page mini map, 0.2–1.0. Defaults to 0.8.
  late final Signal<double> _miniMapOpacity;
  ReadonlySignal<double> get miniMapOpacitySignal => _miniMapOpacity;
  double get miniMapOpacity => _miniMapOpacity.value;

  /// When on, both the lightning map and the camera mini map overlay the latest
  /// precipitation radar frame (from RainViewer's free public API). On by
  /// default — it's a read-only tile fetch with no permissions or relay key.
  late final Signal<bool> _rainRadarEnabled;
  ReadonlySignal<bool> get rainRadarEnabledSignal => _rainRadarEnabled;
  bool get rainRadarEnabled => _rainRadarEnabled.value;

  /// Custom relay URL. When non-empty, the lightning service connects here
  /// instead of the default relay.
  late final Signal<String> _customRelayUrl;
  ReadonlySignal<String> get customRelayUrlSignal => _customRelayUrl;
  String get customRelayUrl => _customRelayUrl.value;

  /// Per-friend key the relay requires to connect. Falls back to the value baked
  /// in at build time with `--dart-define=RELAY_KEY=...` when nothing is saved.
  /// The `const` fallback is required — Flutter only substitutes `--dart-define`
  /// values into constant expressions.
  late final Signal<String> _relayKey;
  ReadonlySignal<String> get relayKeySignal => _relayKey;
  String get relayKey {
    final saved = _relayKey.value;
    if (saved.isNotEmpty) return saved;
    return const String.fromEnvironment('RELAY_KEY');
  }

  /// Relay URLs that have connected successfully, most-recent first (capped at
  /// [_maxRecentRelayUrls]). Surfaced as suggestions under the relay URL field.
  late final Signal<List<String>> _recentRelayUrls;
  ReadonlySignal<List<String>> get recentRelayUrlsSignal => _recentRelayUrls;
  List<String> get recentRelayUrls => _recentRelayUrls.value;

  /// Whether the cache info panel on the camera page is collapsed to a single
  /// line. Toggled by tapping the panel; persisted across restarts.
  late final Signal<bool> _cacheInfoCollapsed;
  ReadonlySignal<bool> get cacheInfoCollapsedSignal => _cacheInfoCollapsed;
  bool get cacheInfoCollapsed => _cacheInfoCollapsed.value;

  /// When set and in the future, the "compass inaccurate" overlay warning is
  /// hidden until this moment. Null means the warning shows whenever accuracy is
  /// poor. Persisted so a dismissal survives app restarts.
  late final Signal<DateTime?> _calibrationSuppressedUntil;
  ReadonlySignal<DateTime?> get calibrationSuppressedUntilSignal =>
      _calibrationSuppressedUntil;

  /// When on, leaving the gallery skips the "unsaved images will be lost"
  /// confirmation and returns to the camera straight away. Off by default; the
  /// user opts in via the dialog's "Never show this again" checkbox.
  late final Signal<bool> _skipGalleryExitWarning;
  ReadonlySignal<bool> get skipGalleryExitWarningSignal =>
      _skipGalleryExitWarning;
  bool get skipGalleryExitWarning => _skipGalleryExitWarning.value;

  /// The shape of the frames the camera captures. Defaults to [wide16x9].
  /// Changing it makes the camera page reconnect at the new resolution.
  late final Signal<CaptureAspect> _captureAspect;
  ReadonlySignal<CaptureAspect> get captureAspectSignal => _captureAspect;
  CaptureAspect get captureAspect => _captureAspect.value;

  /// The camera's last zoom ratio (e.g. 1.0 = "1×"). Remembered so the camera
  /// reopens at the framing the user left it at — phones with an ultra-wide can
  /// go below 1.0. Defaults to 1.0; the camera clamps it to its real range.
  late final Signal<double> _cameraZoom;
  ReadonlySignal<double> get cameraZoomSignal => _cameraZoom;
  double get cameraZoom => _cameraZoom.value;

  /// Which measurement system distances are shown in. Defaults to
  /// [UnitSystem.system], which follows the device locale.
  late final Signal<UnitSystem> _unitSystem;
  ReadonlySignal<UnitSystem> get unitSystemSignal => _unitSystem;
  UnitSystem get unitSystem => _unitSystem.value;

  /// Strikes farther than this from the user aren't drawn on the overlay.
  /// Clamped to [minStrikeDistanceKm]–[maxStrikeDistanceKm]; defaults to 75 km.
  late final Signal<double> _maxStrikeDistanceKm;
  ReadonlySignal<double> get maxStrikeDistanceKmSignal => _maxStrikeDistanceKm;
  double get maxStrikeDistanceKmValue => _maxStrikeDistanceKm.value;

  /// Minimum "Lightning" confidence (0–1) for a captured frame to count as a
  /// detection in the gallery. Clamped to
  /// [minLightningThreshold]–[maxLightningThreshold]; defaults to 0.40. Read
  /// live by the gallery and detection service so changing it re-filters
  /// results without rescanning.
  late final Signal<double> _lightningThreshold;
  ReadonlySignal<double> get lightningThresholdSignal => _lightningThreshold;
  double get lightningThreshold => _lightningThreshold.value;

  /// When on, saved photos are tagged with the device's current GPS location in
  /// their EXIF data. On by default; falls back to saving without a location
  /// when location services or permission aren't available.
  late final Signal<bool> _geotagPhotos;
  ReadonlySignal<bool> get geotagPhotosSignal => _geotagPhotos;
  bool get geotagPhotos => _geotagPhotos.value;

  /// How many columns the gallery grid shows, set by pinching to zoom. Null
  /// means follow the per-orientation default (more columns in landscape). Once
  /// the user pinches, the chosen count is remembered across restarts.
  late final Signal<int?> _galleryCrossAxisCount;
  ReadonlySignal<int?> get galleryCrossAxisCountSignal => _galleryCrossAxisCount;
  int? get galleryCrossAxisCount => _galleryCrossAxisCount.value;

  /// When on, a background service watches the relay and notifies the user when
  /// lightning strikes within [alertRadiusKm] of them — even with the app
  /// closed. Off by default; it runs a persistent foreground service and needs
  /// notification permission.
  late final Signal<bool> _lightningAlertsEnabled;
  ReadonlySignal<bool> get lightningAlertsEnabledSignal =>
      _lightningAlertsEnabled;
  bool get lightningAlertsEnabled => _lightningAlertsEnabled.value;

  /// How close a strike must be to trigger a proximity alert, in kilometres.
  /// Clamped to [minStrikeDistanceKm]–[maxStrikeDistanceKm]; defaults to
  /// [defaultAlertRadiusKm].
  late final Signal<double> _alertRadiusKm;
  ReadonlySignal<double> get alertRadiusKmSignal => _alertRadiusKm;
  double get alertRadiusKm => _alertRadiusKm.value;

  /// How long after a proximity alert before another in-range strike makes a
  /// sound again, in minutes. A markedly closer strike still alerts right away
  /// (see the alert service). Clamped to
  /// [minAlertCooldownMinutes]–[maxAlertCooldownMinutes].
  late final Signal<double> _alertCooldownMinutes;
  ReadonlySignal<double> get alertCooldownMinutesSignal => _alertCooldownMinutes;
  double get alertCooldownMinutes => _alertCooldownMinutes.value;

  /// The latitude/longitude the map was last centered on, persisted so a cold
  /// start — including opening the map straight from an alert notification —
  /// can still open on the user's last known area instead of the world view.
  /// Null until the map has resolved a location at least once.
  double? _lastMapLat;
  double? _lastMapLon;
  double? get lastMapLatitude => _lastMapLat;
  double? get lastMapLongitude => _lastMapLon;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    // Per-orientation shutter positions. The X for each orientation falls back
    // to the old single value (for installs from before this was split out),
    // then to the default. Y is newer still, so it just uses the default.
    final legacyOffsetX = prefs.getDouble(_shutterOffsetXKey);
    final offsets = <DeviceOrientation, Offset>{};
    for (final orientation in DeviceOrientation.values) {
      final x =
          prefs.getDouble(_shutterOffsetXKeyFor(orientation)) ??
          legacyOffsetX ??
          defaultShutterOffset.dx;
      final y =
          prefs.getDouble(_shutterOffsetYKeyFor(orientation)) ??
          defaultShutterOffset.dy;
      offsets[orientation] = Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    }
    _shutterOffsets = signal(offsets);
    _isRepositioning = signal(false);
    _lightningTestMode = signal(prefs.getBool(_lightningTestModeKey) ?? false);
    _showThunderCircles = signal(prefs.getBool(_showThunderCirclesKey) ?? true);
    _thunderLeadSeconds = signal(
      (prefs.getDouble(_thunderLeadSecondsKey) ?? 0).clamp(
        0,
        maxThunderLeadSeconds,
      ),
    );
    _strikeOverlayEnabled = signal(
      prefs.getBool(_strikeOverlayEnabledKey) ?? true,
    );
    _showStrikeInfo = signal(prefs.getBool(_showStrikeInfoKey) ?? true);
    _miniMapEnabled = signal(prefs.getBool(_miniMapEnabledKey) ?? true);
    _miniMapOpacity = signal(prefs.getDouble(_miniMapOpacityKey) ?? 0.4);
    _rainRadarEnabled = signal(prefs.getBool(_rainRadarEnabledKey) ?? true);
    _customRelayUrl = signal(prefs.getString(_customRelayUrlKey) ?? '');
    _relayKey = signal(prefs.getString(_relayKeyKey) ?? '');
    _recentRelayUrls = signal(
      prefs.getStringList(_recentRelayUrlsKey) ?? const [],
    );
    _cacheInfoCollapsed = signal(
      prefs.getBool(_cacheInfoCollapsedKey) ?? false,
    );
    final suppressedMs = prefs.getInt(_calibrationSuppressedUntilKey);
    _calibrationSuppressedUntil = signal(
      suppressedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(suppressedMs),
    );
    _skipGalleryExitWarning = signal(
      prefs.getBool(_skipGalleryExitWarningKey) ?? false,
    );
    final aspectName = prefs.getString(_captureAspectKey);
    _captureAspect = signal(
      CaptureAspect.values.firstWhere(
        (a) => a.name == aspectName,
        orElse: () => CaptureAspect.wide16x9,
      ),
    );
    _cameraZoom = signal(prefs.getDouble(_cameraZoomKey) ?? 1.0);
    final unitName = prefs.getString(_unitSystemKey);
    _unitSystem = signal(
      UnitSystem.values.firstWhere(
        (u) => u.name == unitName,
        orElse: () => UnitSystem.system,
      ),
    );
    final storedDistance = prefs.getDouble(_maxStrikeDistanceKmKey) ?? 75.0;
    _maxStrikeDistanceKm = signal(
      storedDistance.clamp(minStrikeDistanceKm, maxStrikeDistanceKm),
    );
    final storedThreshold = prefs.getDouble(_lightningThresholdKey) ?? 0.40;
    _lightningThreshold = signal(
      storedThreshold.clamp(minLightningThreshold, maxLightningThreshold),
    );
    _geotagPhotos = signal(prefs.getBool(_geotagPhotosKey) ?? true);
    _galleryCrossAxisCount = signal(prefs.getInt(_galleryCrossAxisCountKey));
    _lightningAlertsEnabled = signal(
      prefs.getBool(_lightningAlertsEnabledKey) ?? false,
    );
    final storedRadius =
        prefs.getDouble(_alertRadiusKmKey) ?? defaultAlertRadiusKm;
    _alertRadiusKm = signal(
      storedRadius.clamp(minStrikeDistanceKm, maxStrikeDistanceKm),
    );
    final storedCooldown =
        prefs.getDouble(_alertCooldownMinutesKey) ??
        defaultAlertCooldownMinutes;
    _alertCooldownMinutes = signal(
      storedCooldown.clamp(minAlertCooldownMinutes, maxAlertCooldownMinutes),
    );
    _lastMapLat = prefs.getDouble(_lastMapLatKey);
    _lastMapLon = prefs.getDouble(_lastMapLonKey);
  }

  Future<void> setShutterOffset(
    DeviceOrientation orientation,
    Offset offset,
  ) async {
    final clamped = Offset(
      offset.dx.clamp(0.0, 1.0),
      offset.dy.clamp(0.0, 1.0),
    );
    _shutterOffsets.value = {..._shutterOffsets.value, orientation: clamped};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_shutterOffsetXKeyFor(orientation), clamped.dx);
    await prefs.setDouble(_shutterOffsetYKeyFor(orientation), clamped.dy);
  }

  Future<void> setCameraZoom(double zoom) async {
    _cameraZoom.value = zoom;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_cameraZoomKey, zoom);
  }

  Future<void> setLightningTestMode(bool enabled) async {
    _lightningTestMode.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lightningTestModeKey, enabled);
  }

  Future<void> setShowThunderCircles(bool enabled) async {
    _showThunderCircles.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showThunderCirclesKey, enabled);
  }

  Future<void> setThunderLeadSeconds(double seconds) async {
    final clamped = seconds.clamp(0.0, maxThunderLeadSeconds);
    _thunderLeadSeconds.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_thunderLeadSecondsKey, clamped);
  }

  Future<void> setStrikeOverlayEnabled(bool enabled) async {
    _strikeOverlayEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_strikeOverlayEnabledKey, enabled);
  }

  Future<void> setShowStrikeInfo(bool enabled) async {
    _showStrikeInfo.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showStrikeInfoKey, enabled);
  }

  Future<void> setMiniMapEnabled(bool enabled) async {
    _miniMapEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_miniMapEnabledKey, enabled);
  }

  Future<void> setMiniMapOpacity(double opacity) async {
    _miniMapOpacity.value = opacity.clamp(0.2, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_miniMapOpacityKey, _miniMapOpacity.value);
  }

  Future<void> setRainRadarEnabled(bool enabled) async {
    _rainRadarEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rainRadarEnabledKey, enabled);
  }

  Future<void> setCustomRelayUrl(String url) async {
    _customRelayUrl.value = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customRelayUrlKey, url);
  }

  Future<void> setRelayKey(String key) async {
    _relayKey.value = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_relayKeyKey, key);
  }

  /// Record a relay URL that connected successfully, moving it to the front of
  /// the recent list (de-duplicated, capped at [_maxRecentRelayUrls]). Empty
  /// URLs — i.e. the default relay — are ignored, since there's nothing the user
  /// typed to suggest later.
  Future<void> recordSuccessfulRelayUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;

    final updated = <String>[
      trimmed,
      ..._recentRelayUrls.value.where((u) => u != trimmed),
    ].take(_maxRecentRelayUrls).toList();

    if (listEquals(updated, _recentRelayUrls.value)) return;
    _recentRelayUrls.value = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentRelayUrlsKey, updated);
  }

  Future<void> setCacheInfoCollapsed(bool collapsed) async {
    _cacheInfoCollapsed.value = collapsed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cacheInfoCollapsedKey, collapsed);
  }

  /// Hide the "compass inaccurate" warning for the next 4 hours.
  Future<void> suppressCalibrationWarning() async {
    final until = DateTime.now().add(const Duration(hours: 4));
    _calibrationSuppressedUntil.value = until;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _calibrationSuppressedUntilKey,
      until.millisecondsSinceEpoch,
    );
  }

  Future<void> setSkipGalleryExitWarning(bool skip) async {
    _skipGalleryExitWarning.value = skip;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_skipGalleryExitWarningKey, skip);
  }

  Future<void> setCaptureAspect(CaptureAspect aspect) async {
    _captureAspect.value = aspect;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_captureAspectKey, aspect.name);
  }

  Future<void> setUnitSystem(UnitSystem system) async {
    _unitSystem.value = system;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_unitSystemKey, system.name);
  }

  Future<void> setMaxStrikeDistanceKm(double km) async {
    _maxStrikeDistanceKm.value = km.clamp(
      minStrikeDistanceKm,
      maxStrikeDistanceKm,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_maxStrikeDistanceKmKey, _maxStrikeDistanceKm.value);
  }

  Future<void> setLightningThreshold(double threshold) async {
    _lightningThreshold.value = threshold.clamp(
      minLightningThreshold,
      maxLightningThreshold,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lightningThresholdKey, _lightningThreshold.value);
  }

  Future<void> setGeotagPhotos(bool enabled) async {
    _geotagPhotos.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_geotagPhotosKey, enabled);
  }

  Future<void> setGalleryCrossAxisCount(int count) async {
    _galleryCrossAxisCount.value = count;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_galleryCrossAxisCountKey, count);
  }

  Future<void> setLightningAlertsEnabled(bool enabled) async {
    _lightningAlertsEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lightningAlertsEnabledKey, enabled);
  }

  Future<void> setAlertRadiusKm(double km) async {
    _alertRadiusKm.value = km.clamp(minStrikeDistanceKm, maxStrikeDistanceKm);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_alertRadiusKmKey, _alertRadiusKm.value);
  }

  Future<void> setAlertCooldownMinutes(double minutes) async {
    _alertCooldownMinutes.value = minutes.clamp(
      minAlertCooldownMinutes,
      maxAlertCooldownMinutes,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _alertCooldownMinutesKey,
      _alertCooldownMinutes.value,
    );
  }

  /// Remember the map center for the next cold start. Called from the lightning
  /// service as the resolved location moves.
  Future<void> setLastMapCenter(double latitude, double longitude) async {
    _lastMapLat = latitude;
    _lastMapLon = longitude;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lastMapLatKey, latitude);
    await prefs.setDouble(_lastMapLonKey, longitude);
  }

  void enterRepositionMode() {
    _isRepositioning.value = true;
  }

  void exitRepositionMode() {
    _isRepositioning.value = false;
  }
}
