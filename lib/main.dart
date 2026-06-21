import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:lightingcamera/camera/camera_page.dart';
import 'package:lightingcamera/camera/gallery_page.dart';
import 'package:lightingcamera/lightning/alert_service.dart';
import 'package:lightingcamera/lightning/alert_service_controller.dart';
import 'package:lightingcamera/lightning/lightning_map_page.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/settings/settings_page.dart';
import 'package:lightingcamera/theme/app_theme.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:signals/signals.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Signals attaches a DevTools observer in debug mode that logs every signal
  // update to the console (very noisy with the image cache). Turn it off.
  SignalsObserver.instance = null;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  configureLogging();
  await settingsManager.init();
  // Configure the alert foreground service and reconcile it with the saved
  // setting — start it if alerts are on but it isn't running (e.g. after an
  // app update or the process being killed), stop it if it's stale.
  await alertServiceController.syncToSetting();
  // Wire notification taps and find out whether the app was cold-launched by
  // tapping an alert, so the first screen is the map rather than the camera.
  final initialLocation = await _initNotificationRouting();
  runApp(MyApp(initialLocation: initialLocation));
}

class Pages {
  static String home = "home";
  static String gallery = "gallery";
  static String settings = "settings";
  static String map = "map";

  /// Full path of the map route, for navigation that can't use named routes
  /// (notification taps, initial location).
  static String mapPath = "/map";
}

/// Shared with [MyApp] so a notification tap while the app is already open can
/// route to the map. Built once in [main] with the cold-start location.
GoRouter? _router;

GoRouter _buildRouter(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  // Without this the navigator never notifies the observer, so CameraPage's
  // didPushNext/didPopNext (camera release/reconnect) would never fire.
  observers: [CameraPageState.routeObserver],
  routes: [
    GoRoute(
      name: Pages.home,
      path: '/',
      builder: (context, state) => const MyHomePage(title: 'Lightning Camera'),
      routes: [
        GoRoute(
          name: Pages.gallery,
          path: 'gallery',
          builder: (context, state) => const GalleryPage(),
        ),
        GoRoute(
          name: Pages.settings,
          path: 'settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          name: Pages.map,
          path: 'map',
          builder: (context, state) => const LightningMapPage(),
        ),
      ],
    ),
  ],
);

/// Initialize notification-tap handling for the main isolate and return the
/// route the app should open at. The alert notification is shown by the
/// background service isolate; tapping it launches this isolate, so the tap is
/// handled here. Returns the map path when the app was launched by tapping an
/// alert, otherwise the camera home.
Future<String> _initNotificationRouting() async {
  final notifications = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(
    settings: const InitializationSettings(android: androidInit),
    // Fired when the app is already running and a notification is tapped.
    onDidReceiveNotificationResponse: (response) {
      if (response.payload == alertNotificationPayload) {
        _router?.go(Pages.mapPath);
      }
    },
  );

  final launch = await notifications.getNotificationAppLaunchDetails();
  final tappedAlert = launch?.didNotificationLaunchApp == true &&
      launch?.notificationResponse?.payload == alertNotificationPayload;
  return tappedAlert ? Pages.mapPath : '/';
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.initialLocation});

  final String initialLocation;

  @override
  Widget build(BuildContext context) {
    final router = _router ??= _buildRouter(initialLocation);
    return MaterialApp.router(
      title: 'Lightning Camera',
      theme: buildAppTheme(),
      routerConfig: router,
    );
  }
}

class MyHomePage extends StatelessWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      // Black so the letterbox bars around the full-frame preview read as a
      // camera viewfinder rather than blank theme-colored space.
      backgroundColor: Colors.black,
      body: CameraPage(),
    );
  }
}
