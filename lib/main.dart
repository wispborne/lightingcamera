import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lightingcamera/camera/camera_page.dart';
import 'package:lightingcamera/camera/gallery_page.dart';

void main() {
  runApp(const MyApp());
}

class Pages {
  static String home = "home";
  static String gallery = "gallery";
  static String settings = "settings";
}

final _router = GoRouter(
  routes: [
    GoRoute(
      name: Pages.home,
      path: '/',
      builder: (context, state) => const MyHomePage(title: 'Lightning Camera'),
    ),
    GoRoute(
      name: Pages.gallery,
      path: '/gallery',
      builder: (context, state) => const GalleryPage(),
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

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    //
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: CameraPage(),
    );
  }
}
