import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:lightingcamera/utils/units.dart';

/// Notification channel + id constants, shared with the controller so the
/// monitoring channel the foreground service uses is created before it starts.
const String monitoringChannelId = 'lightning_monitoring';
const String monitoringChannelName = 'Lightning monitoring';
const String alertChannelId = 'lightning_alerts';
const String alertChannelName = 'Lightning alerts';
const int monitoringNotificationId = 7001;
const int alertNotificationId = 7002;

/// Payload set on the proximity alert notification. The main isolate reads it
/// on tap to route to the lightning map instead of the default camera page.
const String alertNotificationPayload = 'open_map';

/// How much wider than the alert radius we subscribe to the relay, so strikes
/// near the edge don't flap in and out of range as the user (or their GPS fix)
/// drifts.
const double _subscriptionBufferKm = 20;

/// The background isolate entrypoint for the lightning alert foreground service.
/// Registered with `FlutterBackgroundService` in the controller. Runs in its own
/// isolate, so it gets fresh `settingsManager` / `lightningService` singletons
/// that it must initialize itself.
@pragma('vm:entry-point')
Future<void> alertServiceOnStart(ServiceInstance service) async {
  // Wire up plugins for this isolate (shared_preferences, geolocator,
  // notifications). Without this their platform channels aren't registered.
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  configureLogging();
  await settingsManager.init();

  final monitor = _AlertMonitor(service);
  await monitor.start();

  service.on('settingsChanged').listen((data) => monitor.onSettingsChanged(data));
  service.on('stop').listen((_) async {
    await monitor.dispose();
    await service.stopSelf();
  });
}

/// Holds the live state of one monitoring run: the relay connection, the latest
/// location fix, and the cooldown bookkeeping for the alert notification.
class _AlertMonitor {
  _AlertMonitor(this._service);

  final ServiceInstance _service;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  /// A service-local relay connection, separate from the app's UI connection.
  final LightningService _lightning = LightningService();
  final Distance _distance = const Distance();

  StreamSubscription<Strike>? _strikeSub;
  StreamSubscription<Position>? _positionSub;

  /// The user's most recent known position, used for the proximity check.
  LatLng? _fix;
  bool _connected = false;

  /// Cooldown state: when the last alert fired and how far that strike was, so
  /// we can stay quiet during a storm but re-alert if one lands much closer.
  DateTime? _lastAlertTime;
  double? _lastAlertDistanceKm;

  Future<void> start() async {
    await _initNotifications();

    // Best starting guess: the last fix the OS already has. The position stream
    // sharpens it as fixes arrive.
    _fix = await _lastKnownLocation();
    _startPositionUpdates();

    _strikeSub = _lightning.strikeStream.listen(_onStrike);
    _connect();
    _updateMonitoringNotification();
  }

  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(
      settings: const InitializationSettings(android: androidInit),
    );
    // The alerts channel is created here too (idempotent) so showing an alert
    // never races the controller's channel setup.
    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        alertChannelId,
        alertChannelName,
        description: 'Alerts when lightning strikes near you.',
        importance: Importance.high,
      ),
    );
  }

  /// Connect (or reconnect) the relay around the current fix, sized to the alert
  /// radius plus a buffer. With no fix yet we stay disconnected and wait for the
  /// position stream to deliver one.
  void _connect() {
    final fix = _fix;
    if (fix == null) {
      _connected = false;
      return;
    }
    final radius = settingsManager.alertRadiusKm + _subscriptionBufferKm;
    _lightning.connect(fix, radiusKm: radius);
    _connected = true;
  }

  void _onStrike(Strike strike) {
    final fix = _fix;
    if (fix == null) return; // can't judge proximity without a location

    final distanceKm = _distance.as(
      LengthUnit.Kilometer,
      fix,
      strike.position,
    );
    if (distanceKm > settingsManager.alertRadiusKm) return; // out of range

    _maybeAlert(distanceKm, strike.position);
  }

  /// Decide whether this in-range strike makes noise (a fresh alert), updates
  /// the existing notification silently (during the cooldown), or re-alerts
  /// because the storm got markedly closer.
  void _maybeAlert(double distanceKm, LatLng strikePos) {
    final now = DateTime.now();
    final last = _lastAlertTime;
    final lastDistance = _lastAlertDistanceKm;

    // The quiet period is user-configurable (minutes); convert to a Duration.
    final cooldown = Duration(
      milliseconds: (settingsManager.alertCooldownMinutes * 60000).round(),
    );
    final cooledDown = last == null || now.difference(last) >= cooldown;
    final muchCloser =
        lastDistance != null && distanceKm <= lastDistance / 2;
    final makeNoise = cooledDown || muchCloser;

    if (makeNoise) {
      _lastAlertTime = now;
      _lastAlertDistanceKm = distanceKm;
    }

    _showAlert(distanceKm, strikePos, sound: makeNoise);
  }

  void _showAlert(double distanceKm, LatLng strikePos, {required bool sound}) {
    final fix = _fix;
    final distanceText = formatDistanceKm(distanceKm, settingsManager.unitSystem);
    var body = 'Lightning $distanceText away';
    if (fix != null) {
      final bearing = _distance.bearing(fix, strikePos);
      body += ' to the ${_compass(bearing)}';
    }

    final details = AndroidNotificationDetails(
      alertChannelId,
      alertChannelName,
      channelDescription: 'Alerts when lightning strikes near you.',
      importance: Importance.high,
      priority: Priority.high,
      // A fresh alert buzzes; a cooldown update reuses the same notification
      // quietly. `onlyAlertOnce` keeps silent updates from re-buzzing.
      playSound: sound,
      enableVibration: sound,
      onlyAlertOnce: !sound,
    );

    _notifications.show(
      id: alertNotificationId,
      title: 'Lightning nearby',
      body: body,
      notificationDetails: NotificationDetails(android: details),
      payload: alertNotificationPayload,
    );
  }

  /// Keep the mandatory foreground-service notification's text current so the
  /// user can see at a glance what the service is doing.
  void _updateMonitoringNotification() {
    final service = _service;
    if (service is! AndroidServiceInstance) return;

    String content;
    if (_fix == null) {
      content = 'Waiting for location…';
    } else {
      final radiusText = formatDistanceKm(
        settingsManager.alertRadiusKm,
        settingsManager.unitSystem,
      );
      content = 'Watching for lightning within $radiusText';
    }
    service.setForegroundNotificationInfo(
      title: 'Lightning alerts',
      content: content,
    );
  }

  Future<LatLng?> _lastKnownLocation() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      if (pos != null) return LatLng(pos.latitude, pos.longitude);
    } catch (e) {
      Fimber.w('Alert service: last known location lookup failed: $e');
    }
    return null;
  }

  /// Follow the user coarsely (same low-accuracy, large-distance-filter settings
  /// the UI lightning feed uses). The first fix may connect the relay; later
  /// fixes just move the subscription box.
  void _startPositionUpdates() {
    _positionSub?.cancel();
    try {
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          distanceFilter: 2000,
        ),
      ).listen(
        (pos) {
          _fix = LatLng(pos.latitude, pos.longitude);
          if (!_connected) {
            _connect();
          } else {
            _lightning.updateCenter(_fix!);
          }
          _updateMonitoringNotification();
        },
        onError: (e) => Fimber.w('Alert service location stream error: $e'),
      );
    } catch (e) {
      Fimber.w('Alert service could not start location updates: $e');
    }
  }

  /// React to a settings change pushed from the main isolate. The payload
  /// carries the new values (signals don't cross isolates), which we write into
  /// this isolate's [settingsManager] before reconnecting with the new radius.
  Future<void> onSettingsChanged(Map<String, dynamic>? data) async {
    if (data != null) {
      await settingsManager.setRelayKey((data['relayKey'] as String?) ?? '');
      await settingsManager.setCustomRelayUrl(
        (data['relayUrl'] as String?) ?? '',
      );
      await settingsManager.setLightningTestMode(
        (data['testMode'] as bool?) ?? false,
      );
      final radius = (data['radiusKm'] as num?)?.toDouble();
      if (radius != null) await settingsManager.setAlertRadiusKm(radius);
      final cooldown = (data['cooldownMinutes'] as num?)?.toDouble();
      if (cooldown != null) {
        await settingsManager.setAlertCooldownMinutes(cooldown);
      }
      final unitName = data['unitSystem'] as String?;
      if (unitName != null) {
        await settingsManager.setUnitSystem(
          UnitSystem.values.firstWhere(
            (u) => u.name == unitName,
            orElse: () => UnitSystem.system,
          ),
        );
      }
    }
    _connect();
    _updateMonitoringNotification();
  }

  /// Map a compass bearing in degrees (0 = north, clockwise) to one of eight
  /// named directions.
  String _compass(double bearingDeg) {
    const points = [
      'north',
      'northeast',
      'east',
      'southeast',
      'south',
      'southwest',
      'west',
      'northwest',
    ];
    final normalized = ((bearingDeg % 360) + 360) % 360;
    return points[(normalized / 45).round() % 8];
  }

  Future<void> dispose() async {
    await _strikeSub?.cancel();
    await _positionSub?.cancel();
    _lightning.disconnect();
    await _notifications.cancel(id: alertNotificationId);
  }
}
