import 'dart:async';
import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:signals/signals.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  /// Relay endpoint. Point this at your VPS relay (see `relay/README.md`).
  /// Use a `wss://` URL in production.
  static const String relayUrl = 'wss://your-vps-host.example/lightning';

  /// How long a strike stays on the map before it's pruned. Configurable here for
  /// now; could be surfaced as a user setting via `settingsManager` later. This is
  /// the display window and is independent of the relay's server-side `maxStrikeAgeMs`.
  static const Duration displayWindow = Duration(minutes: 5);

  /// How far around the user we ask the relay for strikes.
  static const double defaultRadiusKm = 150;

  final ListSignal<Strike> _strikes = listSignal<Strike>([]);
  ReadonlySignal<List<Strike>> get strikes => _strikes;

  final Signal<bool> _connected = signal(false);
  ReadonlySignal<bool> get connected => _connected;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pruneTimer;

  /// Open the relay connection and subscribe to strikes around [center].
  void connect(LatLng center, {double radiusKm = defaultRadiusKm}) {
    disconnect();
    try {
      final channel = WebSocketChannel.connect(Uri.parse(relayUrl));
      _channel = channel;
      channel.sink.add(jsonEncode({
        'lat': center.latitude,
        'lon': center.longitude,
        'radiusKm': radiusKm,
      }));
      _connected.value = true;

      _subscription = channel.stream.listen(
        _onMessage,
        onError: (e) {
          Fimber.e('Lightning relay error: $e');
          _connected.value = false;
        },
        onDone: () {
          _connected.value = false;
        },
      );

      // Age out strikes even when none are arriving, so the map fades to empty.
      _pruneTimer =
          Timer.periodic(const Duration(seconds: 10), (_) => _prune());
    } catch (e) {
      Fimber.e('Failed to connect to lightning relay: $e');
      _connected.value = false;
    }
  }

  void _onMessage(dynamic data) {
    try {
      final map = jsonDecode(data as String) as Map<String, dynamic>;
      final lat = (map['lat'] as num).toDouble();
      final lon = (map['lon'] as num).toDouble();
      final time =
          DateTime.fromMillisecondsSinceEpoch((map['time'] as num).toInt());
      _strikes.add(Strike(LatLng(lat, lon), time));
      _prune();
    } catch (e) {
      Fimber.w('Could not parse strike message: $e');
    }
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(displayWindow);
    _strikes.removeWhere((s) => s.time.isBefore(cutoff));
  }

  void disconnect() {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _connected.value = false;
  }
}
