// Smoke test: boot the real app and confirm the camera route renders.
//
// There's no physical camera in the test harness, so the camera page can't
// finish initializing — it sits on its loading spinner. That's enough to prove
// the app starts up, the router resolves the home route, and CameraPage builds
// without throwing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lightingcamera/main.dart';
import 'package:lightingcamera/settings/settings_manager.dart';

void main() {
  testWidgets('app boots to the camera route', (WidgetTester tester) async {
    // The camera page reads persisted settings as it starts, so back them with
    // an empty in-memory store and initialize the manager before pumping.
    SharedPreferences.setMockInitialValues({});
    await settingsManager.init();

    // '/' is the camera route; MyApp takes the start route explicitly so a
    // notification tap can boot straight to the map instead.
    await tester.pumpWidget(const MyApp(initialLocation: '/'));
    await tester.pump();

    // The app booted into MyApp's router and the camera page is showing its
    // loading state (no real camera to open in the test harness).
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Tear the camera page down and flush its 1-second FPS tick so the test
    // doesn't finish with a pending timer.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
