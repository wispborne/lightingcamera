import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lightingcamera/camera/camera_page.dart';
import 'package:lightingcamera/camera/gallery_page.dart';
import 'package:lightingcamera/lightning/lightning_map_page.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/settings/settings_page.dart';
import 'package:lightingcamera/utils/logging.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  configureLogging();
  await settingsManager.init();
  runApp(const MyApp());
}

class Pages {
  static String home = "home";
  static String gallery = "gallery";
  static String settings = "settings";
  static String map = "map";
}

final _router = GoRouter(
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          brightness: Brightness.dark,
          seedColor: Colors.deepPurple,
        ),
      ),
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
      body: CameraPage(),
    );
  }
}
