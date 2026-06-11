import 'package:flutter/foundation.dart';
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
  static const _shutterOffsetXKey = 'shutter_offset_x';
  static const _lightningTestModeKey = 'lightning_test_mode';
  static const _showThunderCirclesKey = 'show_thunder_circles';
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
  static const _unitSystemKey = 'unit_system';
  static const _maxStrikeDistanceKmKey = 'max_strike_distance_km';

  /// Bounds for the overlay's maximum strike distance, in kilometres.
  static const double minStrikeDistanceKm = 5;
  static const double maxStrikeDistanceKm = 100;

  late final Signal<double> _shutterOffsetX;
  ReadonlySignal<double> get shutterOffsetXSignal => _shutterOffsetX;
  double get shutterOffsetX => _shutterOffsetX.value;

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

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_shutterOffsetXKey) ?? 0.0;
    _shutterOffsetX = signal(stored);
    _isRepositioning = signal(false);
    _lightningTestMode = signal(prefs.getBool(_lightningTestModeKey) ?? false);
    _showThunderCircles = signal(prefs.getBool(_showThunderCirclesKey) ?? true);
    _strikeOverlayEnabled = signal(
      prefs.getBool(_strikeOverlayEnabledKey) ?? false,
    );
    _showStrikeInfo = signal(prefs.getBool(_showStrikeInfoKey) ?? true);
    _miniMapEnabled = signal(prefs.getBool(_miniMapEnabledKey) ?? false);
    _miniMapOpacity = signal(prefs.getDouble(_miniMapOpacityKey) ?? 0.8);
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
  }

  Future<void> setShutterOffsetX(double offset) async {
    _shutterOffsetX.value = offset.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_shutterOffsetXKey, _shutterOffsetX.value);
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

  void enterRepositionMode() {
    _isRepositioning.value = true;
  }

  void exitRepositionMode() {
    _isRepositioning.value = false;
  }
}
