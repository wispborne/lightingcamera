import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:signals/signals.dart';

import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';

/// Top-level singleton (same pattern as `lightningService` / `settingsManager`).
final rainRadarService = RainRadarService();

/// Tracks the newest precipitation radar frame from RainViewer's free public API
/// and exposes it as a flutter_map tile URL template.
///
/// Ref-counted like [LightningService]: each map view [acquire]s while it's on
/// screen and [release]s when it leaves, so the index is only polled while a map
/// that can show radar is visible *and* the setting is on. Provider details (the
/// RainViewer host and tile URL shape) live here alone, so swapping sources later
/// — if RainViewer's free tier disappears — touches only this file.
class RainRadarService {
  /// Frame index: lists past radar frames and the tile host. No API key.
  static const String _indexUrl =
      'https://api.rainviewer.com/public/weather-maps.json';

  /// How often we re-fetch the index. New frames publish about every 10 minutes;
  /// polling at 5 keeps the layer reasonably current without churn.
  static const Duration _pollInterval = Duration(minutes: 5);

  /// Network calls give up after this. A slow or dead endpoint must never block
  /// the UI — a missed poll just means the layer holds its last frame (until it
  /// goes stale) and tries again next tick.
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// Hide the layer once the newest known frame is older than this, so a failing
  /// index endpoint can't leave outdated rain on screen looking current.
  static const Duration _maxFrameAge = Duration(minutes: 30);

  /// RainViewer tile parameters baked into the URL: 256px tiles, the Universal
  /// Blue colour scheme (`2`), smoothing on + snow shown (`1_1`).
  static const String _tileSize = '256';
  static const String _colorScheme = '2';
  static const String _options = '1_1';

  /// Highest zoom RainViewer actually renders radar tiles at (for 256px tiles).
  /// Beyond this it serves a static "Zoom level not supported" placeholder, so
  /// maps must stop requesting native tiles here and upscale the z7 tile for
  /// closer views instead. Verified against the live API on 2026-06-10.
  static const int maxNativeZoom = 7;

  final Signal<String?> _tileUrlTemplate = signal(null);

  /// The current frame's flutter_map URL template, or null when there's nothing
  /// safe to show: no frame fetched yet, the setting is off, no holders, or the
  /// newest frame has gone stale. Maps read this and simply omit the layer when
  /// it's null.
  ReadonlySignal<String?> get tileUrlTemplate => _tileUrlTemplate;

  Timer? _timer;
  int _refCount = 0;
  bool _watchingSetting = false;

  // Newest frame the last successful fetch found. Kept apart from the template
  // so the staleness check can re-evaluate it without re-fetching.
  String? _host;
  String? _latestPath;
  DateTime? _latestFrameTime;

  /// Register a map view as needing radar. The first holder kicks off polling
  /// (if the setting is on); later holders just share it.
  void acquire() {
    _ensureSettingWatch();
    _refCount++;
    _evaluate();
  }

  /// Release a map view. Polling stops once the last holder lets go.
  void release() {
    if (_refCount == 0) return;
    _refCount--;
    _evaluate();
  }

  /// Watch the radar setting so toggling it takes effect immediately, even while
  /// a map is already holding the service. Registered lazily on first [acquire],
  /// by which point [settingsManager] is initialized.
  void _ensureSettingWatch() {
    if (_watchingSetting) return;
    _watchingSetting = true;
    effect(() {
      // Reading the signal here subscribes us to its changes.
      settingsManager.rainRadarEnabledSignal.value;
      _evaluate();
    });
  }

  /// Start or stop polling based on whether anything needs radar right now, then
  /// refresh the template so the change shows without waiting for a poll tick.
  void _evaluate() {
    final shouldRun = _refCount > 0 && settingsManager.rainRadarEnabled;
    if (shouldRun) {
      _startPolling();
    } else {
      _stopPolling();
    }
    _refreshTemplate();
  }

  void _startPolling() {
    if (_timer != null) return;
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
    _poll(); // don't wait a full interval for the first frame
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fetch the index and remember the newest frame. Failures are logged and
  /// swallowed — the template is refreshed regardless so an aging frame still
  /// goes stale on schedule even while fetches keep failing.
  Future<void> _poll() async {
    try {
      final client = HttpClient()..connectionTimeout = _requestTimeout;
      try {
        final request = await client.getUrl(Uri.parse(_indexUrl));
        final response = await request.close().timeout(_requestTimeout);
        if (response.statusCode != 200) {
          Fimber.w('Rain radar index returned HTTP ${response.statusCode}');
          return;
        }
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(_requestTimeout);
        final map = jsonDecode(body) as Map<String, dynamic>;
        final host = map['host'] as String?;
        final past = (map['radar'] as Map<String, dynamic>?)?['past'];
        if (host == null || past is! List || past.isEmpty) {
          Fimber.w('Rain radar index had no frames.');
          return;
        }
        final newest = past.last as Map<String, dynamic>;
        final path = newest['path'] as String?;
        final time = newest['time'];
        if (path == null || time is! num) {
          Fimber.w('Rain radar frame was malformed.');
          return;
        }
        _host = host;
        _latestPath = path;
        _latestFrameTime = DateTime.fromMillisecondsSinceEpoch(
          time.toInt() * 1000,
        );
      } finally {
        client.close();
      }
    } catch (e) {
      Fimber.e('Rain radar fetch failed: $e');
    }
    _refreshTemplate();
  }

  /// Recompute [_tileUrlTemplate] from the current frame, setting, and clock.
  /// Null whenever there's nothing safe to show (see [tileUrlTemplate]).
  void _refreshTemplate() {
    if (_refCount == 0 || !settingsManager.rainRadarEnabled) {
      _tileUrlTemplate.value = null;
      return;
    }
    final host = _host;
    final path = _latestPath;
    final time = _latestFrameTime;
    if (host == null || path == null || time == null) {
      _tileUrlTemplate.value = null;
      return;
    }
    if (DateTime.now().difference(time) > _maxFrameAge) {
      _tileUrlTemplate.value = null;
      return;
    }
    _tileUrlTemplate.value =
        '$host$path/$_tileSize/{z}/{x}/{y}/$_colorScheme/$_options.png';
  }
}
