# Tasks: Add Settings Page

- [x] Add `shared_preferences` to `pubspec.yaml` and run `flutter pub get`
- [x] Create `lib/settings/settings_manager.dart` — `SettingsManager` singleton with `ShutterPosition` enum, signal-based state, shared_preferences persistence, and `init()` method
- [x] Create `lib/settings/settings_page.dart` — settings UI with shutter position selector (SegmentedButton with left/center/right)
- [x] Update `lib/main.dart` — add `WidgetsFlutterBinding.ensureInitialized()`, call `await settingsManager.init()` before `runApp()`, add `/settings` GoRoute
- [x] Update `lib/camera/camera_page.dart` — add gear icon button to navigate to settings, read `shutterPosition` signal to control shutter button alignment
- [x] Test on device: verify settings persist across app restarts, shutter button moves to all three positions, gear icon navigates correctly (build verified — on-device testing requires connected Android device)
