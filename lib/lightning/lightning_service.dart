import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:signals/signals.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:lightingcamera/lightning/storm_simulator.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';

/// A single lightning strike: where and when.
class Strike {
  final LatLng position;
  final DateTime time;

  const Strike(this.position, this.time);
}

/// Top-level singleton (same pattern as `imageCacheManager` / `settingsManager`).
final lightningService = LightningService();

class LightningService {
  static const String defaultRelayUrl = 'wss://lightning.wispborne.com';

  /// Relay close codes the app reacts to. 4001 (bad key) and 4003 (banned) are
  /// terminal — reconnecting would only get the IP banned or stay rejected. The
  /// others are transient and trigger a backed-off reconnect.
  static const int closeUnauthorized = 4001;
  static const int closeSessionExpired = 4002;
  static const int closeBanned = 4003;

  String get _effectiveRelayUrl {
    final custom = settingsManager.customRelayUrl;
    return custom.isNotEmpty ? custom : defaultRelayUrl;
  }

  /// How long a strike stays on the map before it's pruned. Configurable here for
  /// now; could be surfaced as a user setting via `settingsManager` later. This is
  /// the display window and is independent of the relay's server-side `maxStrikeAgeMs`.
  static const Duration displayWindow = Duration(minutes: 5);

  /// How far around the user we ask the relay for strikes.
  static const double defaultRadiusKm = 150;

  /// The client treats the relay link as dead if nothing — not even a keepalive
  /// — arrives within this window, and forces a reconnect. This catches half-open
  /// connections (a dropped mobile network) that the OS hasn't torn down, where
  /// the socket looks open but no [_onDone] ever fires. Keep it above 2× the
  /// relay's `server.heartbeatMs` (30s) so a single dropped keepalive doesn't
  /// trigger a needless reconnect.
  static const Duration staleTimeout = Duration(seconds: 75);

  /// Re-subscribe to the relay only once the user moves at least this far from
  /// the subscribed center. The box radius ([defaultRadiusKm]) is large, so
  /// smaller movements don't change what's relevant — this keeps GPS jitter from
  /// churning the subscription on every fix.
  static const double resubscribeThresholdKm = 10;

  /// How often the test-mode storm front advances and drops a burst.
  static const Duration testStrikeInterval = Duration(seconds: 20);

  /// Simulated strikes land within this distance of the GPS location.
  /// 20 miles ≈ 32.19 km.
  static const double testRadiusKm = 32.19;

  final ListSignal<Strike> _strikes = listSignal<Strike>([]);
  ReadonlySignal<List<Strike>> get strikes => _strikes;

  /// The most recent center any holder resolved and acquired with. Lets a page
  /// (e.g. the map) open at the user's location immediately instead of waiting
  /// for its own fresh GPS fix. Null until the first [acquire].
  LatLng? lastCenter;

  final Signal<bool> _connected = signal(false);
  ReadonlySignal<bool> get connected => _connected;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pruneTimer;
  Timer? _reconnectTimer;
  Timer? _staleTimer;
  StreamSubscription<Position>? _positionSub;
  StormSimulator? _simulator;

  /// Computes great-circle distances for the move-far-enough check in
  /// [updateCenter]. Stateless, so one shared instance is fine.
  static final Distance _distance = const Distance();

  /// The subscription target for the current connection, kept so we can
  /// re-subscribe after the relay's auth ack and after an automatic reconnect.
  LatLng? _center;
  double _radiusKm = defaultRadiusKm;

  /// Set when the user (or last holder) closed the connection on purpose, so the
  /// reconnect logic stays quiet. Cleared on the next [connect].
  bool _manualDisconnect = false;

  /// Number of consecutive reconnect attempts, used for exponential backoff.
  int _reconnectAttempts = 0;

  /// Number of live holders (camera overlay, map page). The connection is kept
  /// open while at least one holder needs it, so neither page tears the other's
  /// feed down. See [acquire] / [release].
  int _refCount = 0;

  /// Whether the relay-settings watcher has been wired up yet. Set once, lazily,
  /// on the first [acquire]. See [_ensureCredentialWatch].
  bool _watchingCredentials = false;

  /// Open the connection for a holder. The first holder connects around
  /// [center]; later holders just share the existing connection (first center
  /// wins — both pages use the same device GPS, so they're effectively equal).
  void acquire(LatLng center, {double radiusKm = defaultRadiusKm}) {
    _ensureCredentialWatch();
    lastCenter = center;
    if (_refCount == 0) {
      connect(center, radiusKm: radiusKm);
    }
    _refCount++;
  }

  /// Watch the relay key, URL, and test-mode setting so a change takes effect
  /// immediately — even while a page is already holding the connection. Without
  /// this, a key entered *after* a holder acquired (e.g. the camera overlay
  /// acquired at launch with no key, so [connect] bailed out but [_refCount] is
  /// already non-zero) would never take effect, leaving every page "Disconnected"
  /// until the holders are fully released. Registered lazily on the first
  /// [acquire], by which point [settingsManager] is initialized.
  void _ensureCredentialWatch() {
    if (_watchingCredentials) return;
    _watchingCredentials = true;

    var prevKey = settingsManager.relayKeySignal.value;
    var prevUrl = settingsManager.customRelayUrlSignal.value;
    var prevTestMode = settingsManager.lightningTestModeSignal.value;

    effect(() {
      // Reading these inside the effect subscribes us to their changes.
      final key = settingsManager.relayKeySignal.value;
      final url = settingsManager.customRelayUrlSignal.value;
      final testMode = settingsManager.lightningTestModeSignal.value;

      final changed =
          key != prevKey || url != prevUrl || testMode != prevTestMode;
      prevKey = key;
      prevUrl = url;
      prevTestMode = testMode;
      if (!changed) return; // initial run, or an unrelated rebuild

      // Only reconnect while something actually needs the feed; with no holders
      // the next acquire() picks up the new settings on its own.
      if (_refCount == 0) return;
      final center = lastCenter ?? _center;
      if (center == null) return;
      Fimber.i('Relay settings changed — reconnecting the lightning feed.');
      connect(center, radiusKm: _radiusKm);
    });
  }

  /// Release a holder. The connection closes only once the last holder lets go.
  void release() {
    if (_refCount == 0) return;
    _refCount--;
    if (_refCount == 0) {
      disconnect();
    }
  }

  /// Open the relay connection and subscribe to strikes around [center].
  ///
  /// When `settingsManager.lightningTestMode` is on, no relay connection is
  /// made — instead fake strikes are generated around [center] every
  /// [testStrikeInterval].
  void connect(LatLng center, {double radiusKm = defaultRadiusKm}) {
    disconnect();
    _manualDisconnect = false;
    _reconnectAttempts = 0;
    _center = center;
    _radiusKm = radiusKm;

    // Test mode comes first — it makes no relay connection and needs no key.
    if (settingsManager.lightningTestMode) {
      _startSimulation(center);
      return;
    }

    // No point connecting without a key: the relay would just reject us.
    if (settingsManager.relayKey.isEmpty) {
      Fimber.i('No relay key set — not connecting to the lightning relay.');
      _connected.value = false;
      return;
    }

    _openConnection();
    // Follow the user: move the subscription box as their GPS location changes.
    _startLocationUpdates();
  }

  /// Open the websocket, send the auth message, and wire up listeners. The
  /// connection is only considered "connected" once the relay acks the key (see
  /// [_onMessage]); a failed auth or transient drop is handled in [_onDone].
  void _openConnection() {
    final key = settingsManager.relayKey;
    if (key.isEmpty) return;

    try {
      final channel = WebSocketChannel.connect(Uri.parse(_effectiveRelayUrl));
      _channel = channel;
      // First message must be the auth key. We subscribe only after the ack.
      channel.sink.add(jsonEncode({'auth': key}));

      _subscription = channel.stream.listen(
        _onMessage,
        onError: (e) {
          Fimber.e('Lightning relay error: $e');
          _connected.value = false;
        },
        onDone: _onDone,
      );

      // Age out strikes even when none are arriving, so the map fades to empty.
      _pruneTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _prune(),
      );

      // Start the dead-link watchdog. The relay's keepalive (or any strike)
      // resets it; prolonged silence forces a reconnect.
      _resetStaleTimer();
    } catch (e) {
      Fimber.e('Failed to connect to lightning relay: $e');
      _connected.value = false;
      _scheduleReconnect();
    }
  }

  /// Handle the socket closing. Reconnect with backoff on a transient drop or
  /// session expiry, but never on a bad key or ban — retrying those would only
  /// get the device's IP banned (or stay rejected).
  void _onDone() {
    _connected.value = false;
    // The link is already known dead; the watchdog has nothing left to catch.
    _staleTimer?.cancel();
    _staleTimer = null;
    if (_manualDisconnect) return;

    final code = _channel?.closeCode;
    if (code == closeUnauthorized || code == closeBanned) {
      Fimber.w(
        'Lightning relay rejected the connection (code $code) — not retrying. '
        'Check your relay key in Settings.',
      );
      return;
    }
    _scheduleReconnect();
  }

  /// Reconnect after an exponential backoff (1s, 2s, 4s, 8s, … capped at 30s).
  void _scheduleReconnect() {
    if (_manualDisconnect || settingsManager.relayKey.isEmpty) return;

    _reconnectTimer?.cancel();
    final delaySeconds = math.min(30, math.pow(2, _reconnectAttempts).toInt());
    _reconnectAttempts++;
    Fimber.i('Reconnecting to lightning relay in ${delaySeconds}s');

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      // Tear down the dead channel but keep the reconnect/center state.
      _subscription?.cancel();
      _subscription = null;
      _channel?.sink.close();
      _channel = null;
      _pruneTimer?.cancel();
      _pruneTimer = null;
      _staleTimer?.cancel();
      _staleTimer = null;
      _openConnection();
    });
  }

  /// Simulate a storm front sweeping across the area around [center].
  void _startSimulation(LatLng center) {
    _connected.value = true;
    Fimber.i('Lightning test mode: simulating a storm front around $center');

    _simulator = StormSimulator(
      center: center,
      radiusKm: testRadiusKm,
      interval: testStrikeInterval,
      onStrike: (point) {
        _strikes.add(Strike(point, DateTime.now()));
        _prune();
      },
    )..start();

    _pruneTimer = Timer.periodic(const Duration(seconds: 10), (_) => _prune());
  }

  void _onMessage(dynamic data) {
    // Any traffic — a strike or a keepalive — proves the link is alive.
    _resetStaleTimer();
    try {
      final map = jsonDecode(data as String) as Map<String, dynamic>;
      final type = map['type'];

      // Auth ack: the relay accepted our key. A legacy relay sends {ok:true} with
      // no type, so accept that too.
      if (type == 'ack' || map['ok'] == true) {
        _onAuthAck();
        return;
      }

      // Keepalive — nothing to do beyond the stale-timer reset above.
      if (type == 'ping') return;

      // History replay: the relay's recent strikes for our box, sent after each
      // subscription. Replace the list — the backlog is authoritative for the
      // current box, and replacing makes duplicates impossible. Old relays never
      // send this; the map just stays empty until live strikes arrive.
      if (type == 'backlog') {
        final entries = map['strikes'];
        if (entries is! List) return;
        final strikes = <Strike>[];
        for (final entry in entries) {
          // Skip malformed entries individually so one bad strike can't blank
          // the whole seed.
          if (entry is! Map) continue;
          final lat = entry['lat'];
          final lon = entry['lon'];
          final time = entry['time'];
          if (lat is! num || lon is! num || time is! num) continue;
          strikes.add(
            Strike(
              LatLng(lat.toDouble(), lon.toDouble()),
              DateTime.fromMillisecondsSinceEpoch(time.toInt()),
            ),
          );
        }
        Fimber.i('Seeded ${strikes.length} strikes from the relay backlog.');
        _strikes.value = strikes;
        _prune();
        return;
      }

      // A strike. New relays tag it type:'strike'; older ones just send lat/lon.
      if (type == 'strike' || (map['lat'] != null && map['lon'] != null)) {
        final lat = (map['lat'] as num).toDouble();
        final lon = (map['lon'] as num).toDouble();
        final time = DateTime.fromMillisecondsSinceEpoch(
          (map['time'] as num).toInt(),
        );
        _strikes.add(Strike(LatLng(lat, lon), time));
        _prune();
        return;
      }

      // Unknown message type: ignore it so the relay can add new messages
      // without breaking older app builds.
      Fimber.d('Ignoring unknown relay message: $map');
    } catch (e) {
      Fimber.w('Could not parse relay message: $e');
    }
  }

  /// The relay accepted our key. Mark connected, reset the reconnect backoff,
  /// remember a working custom URL, and send the subscription for the current
  /// center. Runs on every (re)connect, since each one re-authenticates.
  void _onAuthAck() {
    _connected.value = true;
    _reconnectAttempts = 0;
    // Remember a working custom URL so the settings field can suggest it.
    // (Empty means the default relay, which isn't worth suggesting.)
    settingsManager.recordSuccessfulRelayUrl(settingsManager.customRelayUrl);
    _sendSubscription();
  }

  /// Send the subscription box for the current center, if we have one and the
  /// socket is live. Used after the auth ack and whenever the center moves.
  void _sendSubscription() {
    final center = _center;
    if (center == null) return;
    _channel?.sink.add(
      jsonEncode({
        'lat': center.latitude,
        'lon': center.longitude,
        'radiusKm': _radiusKm,
      }),
    );
  }

  /// (Re)arm the dead-link watchdog. Called on connect and on every message, so
  /// the timer only fires after a full [staleTimeout] of total silence.
  void _resetStaleTimer() {
    _staleTimer?.cancel();
    _staleTimer = Timer(staleTimeout, _onStaleLink);
  }

  /// No traffic — not even a keepalive — has arrived within [staleTimeout], so
  /// the socket is almost certainly a half-open connection the OS hasn't torn
  /// down. Drop it and reconnect with backoff; without this the app would look
  /// "connected" while silently receiving nothing.
  void _onStaleLink() {
    Fimber.w(
      'No traffic from the lightning relay in ${staleTimeout.inSeconds}s — '
      'reconnecting.',
    );
    _staleTimer = null;
    _connected.value = false;
    // Cancel the subscription before closing so the close doesn't fire a second
    // reconnect through [_onDone]; then schedule the reconnect ourselves.
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _scheduleReconnect();
  }

  /// Stream coarse GPS fixes and move the subscription box as the user travels
  /// (see [updateCenter]). Started with a real relay connection, stopped on
  /// [disconnect]. Test mode doesn't use this — its storm is fixed in place.
  void _startLocationUpdates() {
    _positionSub?.cancel();
    try {
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          // Metres; coarse on purpose. The km threshold in [updateCenter] is
          // what actually gates a re-subscribe.
          distanceFilter: 2000,
        ),
      ).listen(
        (pos) => updateCenter(LatLng(pos.latitude, pos.longitude)),
        onError: (e) => Fimber.w('Lightning location stream error: $e'),
      );
    } catch (e) {
      Fimber.w('Could not start lightning location updates: $e');
    }
  }

  /// Move the subscription box to follow the user. Ignored until they've moved at
  /// least [resubscribeThresholdKm] from the current center, so GPS jitter and
  /// small movements don't churn the subscription. Safe to call before the auth
  /// ack: the new center is picked up when the subscription is next sent.
  void updateCenter(LatLng center) {
    lastCenter = center;
    final current = _center;
    if (current != null &&
        _distance.as(LengthUnit.Kilometer, current, center) <
            resubscribeThresholdKm) {
      return;
    }
    _center = center;
    Fimber.i('Lightning subscription following the user to $center.');
    if (_connected.value) _sendSubscription();
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(displayWindow);
    _strikes.removeWhere((s) => s.time.isBefore(cutoff));
  }

  /// Try to connect *and authenticate* against [url] with [key]. With
  /// first-message auth the handshake alone succeeds for anyone — the relay only
  /// rejects after its auth timeout — so a real check has to send the key and
  /// wait for the `{ "ok": true }` ack.
  static Future<(bool success, String message)> testConnection(
    String url,
    String key,
  ) async {
    final uri = Uri.parse(url);
    if (!['ws', 'wss'].contains(uri.scheme)) {
      return (false, 'URL must start with ws:// or wss://');
    }
    if (key.isEmpty) {
      return (false, 'Enter a relay key first');
    }

    WebSocketChannel? channel;
    StreamSubscription? sub;
    try {
      channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 5));
      channel.sink.add(jsonEncode({'auth': key}));

      final result = Completer<(bool, String)>();
      sub = channel.stream.listen(
        (data) {
          try {
            final map = jsonDecode(data as String) as Map<String, dynamic>;
            final acked = map['type'] == 'ack' || map['ok'] == true;
            if (acked && !result.isCompleted) {
              result.complete((true, 'Authenticated successfully'));
            }
          } catch (_) {
            // Ignore anything that isn't the ack we're waiting for.
          }
        },
        onError: (e) {
          if (!result.isCompleted) result.complete((false, 'Connection failed: $e'));
        },
        onDone: () {
          if (result.isCompleted) return;
          final code = channel!.closeCode;
          result.complete(
            code == closeUnauthorized
                ? (false, 'Invalid relay key')
                : (false, 'Connection closed (code $code)'),
          );
        },
      );

      return await result.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => (false, 'Timed out waiting for authentication'),
      );
    } on TimeoutException {
      return (false, 'Connection timed out');
    } catch (e) {
      return (false, 'Connection failed: $e');
    } finally {
      await sub?.cancel();
      await channel?.sink.close();
    }
  }

  void disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    _positionSub?.cancel();
    _positionSub = null;
    _simulator?.stop();
    _simulator = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _connected.value = false;
  }
}
