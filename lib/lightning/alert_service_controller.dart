import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:lightingcamera/lightning/alert_service.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';

/// Main-isolate control surface for the lightning alert foreground service.
/// Owns configuration, start/stop, permission requests, and pushing settings
/// changes into the running service isolate.
class AlertServiceController {
  AlertServiceController._();
  static final AlertServiceController instance = AlertServiceController._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _configured = false;

  /// Register the service and create its notification channels. Safe to call
  /// repeatedly; only the first call does the work. Must run before
  /// [start] and before the OS can auto-start the service on boot, so call it
  /// from app startup.
  Future<void> configure() async {
    if (_configured) return;
    _configured = true;

    await _createChannels();

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: alertServiceOnStart,
        autoStart: false,
        isForegroundMode: true,
        autoStartOnBoot: true,
        notificationChannelId: monitoringChannelId,
        initialNotificationTitle: 'Lightning alerts',
        initialNotificationContent: 'Starting…',
        foregroundServiceNotificationId: monitoringNotificationId,
        foregroundServiceTypes: const [
          AndroidForegroundType.dataSync,
          AndroidForegroundType.location,
        ],
      ),
      // The app is Android-only; iOS config is a required no-op.
      iosConfiguration: IosConfiguration(autoStart: false),
    );
  }

  /// Create the monitoring (silent, persistent) and alert (high-importance)
  /// notification channels. The monitoring channel must exist before the
  /// foreground service starts using it.
  Future<void> _createChannels() async {
    final plugin = FlutterLocalNotificationsPlugin();
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        monitoringChannelId,
        monitoringChannelName,
        description: 'Shows while the app is watching for nearby lightning.',
        importance: Importance.low,
        showBadge: false,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        alertChannelId,
        alertChannelName,
        description: 'Alerts when lightning strikes near you.',
        importance: Importance.high,
      ),
    );
  }

  Future<bool> isRunning() => _service.isRunning();

  /// Request notification permission and start the service. Returns false if the
  /// user denies notifications — the caller should revert the toggle.
  Future<bool> start() async {
    await configure();

    final status = await Permission.notification.request();
    if (!status.isGranted) {
      Fimber.i('Notification permission denied — not starting alert service.');
      return false;
    }

    if (!await _service.isRunning()) {
      await _service.startService();
    }
    notifySettingsChanged();
    return true;
  }

  /// Stop the service and remove its persistent notification.
  Future<void> stop() async {
    if (await _service.isRunning()) {
      _service.invoke('stop');
    }
  }

  /// Push the current relay + radius + unit settings into the running service so
  /// a change takes effect without restarting it. No-op if not running.
  void notifySettingsChanged() {
    _service.invoke('settingsChanged', {
      // The saved key only — the service isolate runs the same binary, so its
      // own relayKey getter applies the built-in fallback. Sending the
      // effective key would make the service persist the fallback to disk.
      'relayKey': settingsManager.savedRelayKey,
      'relayUrl': settingsManager.customRelayUrl,
      'testMode': settingsManager.lightningTestMode,
      'radiusKm': settingsManager.alertRadiusKm,
      'cooldownMinutes': settingsManager.alertCooldownMinutes,
      'unitSystem': settingsManager.unitSystem.name,
    });
  }

  /// Re-sync the service to the saved setting on app launch: start it if alerts
  /// are enabled but it isn't running, stop it if it's running but disabled.
  Future<void> syncToSetting() async {
    await configure();
    final enabled = settingsManager.lightningAlertsEnabled;
    final running = await _service.isRunning();
    if (enabled && !running) {
      await _service.startService();
      notifySettingsChanged();
    } else if (!enabled && running) {
      _service.invoke('stop');
    } else if (enabled && running) {
      notifySettingsChanged();
    }
  }
}

/// Convenience accessor matching the app's other singletons.
final alertServiceController = AlertServiceController.instance;
