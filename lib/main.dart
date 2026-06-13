import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lightingcamera/camera/camera_page.dart';
import 'package:lightingcamera/camera/gallery_page.dart';
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
  runApp(const MyApp());
}

class Pages {
  static String home = "home";
  static String gallery = "gallery";
  static String settings = "settings";
  static String map = "map";
}

final _router = GoRouter(
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Lightning Camera',
      theme: buildAppTheme(),
      routerConfig: _router,
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
