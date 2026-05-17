# Tasks: Migrate from Riverpod to Signals

- [x] Update `pubspec.yaml`: remove `flutter_riverpod: ^3.3.1`, add `signals: ^6.3.0`, run `flutter pub get`
- [x] Rewrite `lib/camera/image_cache_manager.dart`: remove `ChangeNotifier`/`ChangeNotifierProvider`, use signals for reactive state, export a top-level `imageCacheManager` singleton
- [x] Update `lib/main.dart`: remove `ProviderScope` wrapper and `flutter_riverpod` import
- [x] Update `lib/camera/camera_page.dart`: revert to `StatefulWidget`/`State`, replace all `ref.read(imageCacheProvider)` with direct `imageCacheManager` access
- [x] Update `lib/camera/gallery_page.dart`: revert to `StatefulWidget`/`State`, replace all `ref.read(imageCacheProvider)` with direct `imageCacheManager` access
- [x] Verify the app compiles with `flutter analyze` (no Riverpod references remain)
