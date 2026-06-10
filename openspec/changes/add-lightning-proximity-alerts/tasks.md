# Tasks: Lightning Proximity Alerts

## Dependencies & Platform Setup

- [ ] Add `flutter_background_service` and `flutter_local_notifications` to `pubspec.yaml` and run `flutter pub get`
- [ ] Add manifest permissions: `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `FOREGROUND_SERVICE_LOCATION`, `RECEIVE_BOOT_COMPLETED`
- [ ] Declare the background service in `AndroidManifest.xml` with `foregroundServiceType="dataSync|location"`

## Settings

- [ ] Add `lightningAlertsEnabled` (bool, default false) and `alertRadiusKm` (double, default 15, clamped 5–100) to `SettingsManager` with signals, getters, setters, and persistence
- [ ] Add an "Alerts" section to `SettingsPage`: enable toggle and radius slider (slider disabled while the toggle is off; current value shown as "NN km")
- [ ] Block enabling when no relay key is set and test mode is off, with an explanatory message

## Strike Event Hook

- [ ] Add a broadcast `strikeStream` to `LightningService`, emitting every strike added in `_onMessage` and the simulator callback

## Alert Service

- [ ] Create `lib/lightning/alert_service_controller.dart`: configure `FlutterBackgroundService` (foreground mode, `autoStartOnBoot`, monitoring notification channel), with `start()`, `stop()`, and `notifySettingsChanged()`
- [ ] Create `lib/lightning/alert_service.dart` with the `@pragma('vm:entry-point')` service entrypoint: init `Fimber`, `settingsManager`, and `flutter_local_notifications`; create the two notification channels
- [ ] In the entrypoint, resolve a starting location (last known fix, falling back to "waiting for location" state) and start a service-local `LightningService` with `radiusKm = alertRadiusKm + 20`
- [ ] Implement proximity check on `strikeStream`: distance + 8-point compass bearing from current fix, compare against `alertRadiusKm`
- [ ] Implement alert notification posting with 5-minute cooldown: silent update of the same notification during cooldown, one-time bypass when a strike is ≤ half the last alerted distance
- [ ] Handle `settingsChanged` (re-read prefs, reconnect with new radius) and `stop` messages in the service isolate
- [ ] Keep the persistent monitoring notification text current: "Watching for lightning within NN km" / "Waiting for location…"

## Wiring

- [ ] On settings toggle on: request `POST_NOTIFICATIONS` via `permission_handler`, revert the toggle with a SnackBar on denial, then start the service; on toggle off: stop the service
- [ ] Push radius/relay-key/relay-URL/test-mode changes to a running service via `notifySettingsChanged()`
- [ ] In `main.dart`, re-sync on launch: if `lightningAlertsEnabled` but the service is not running, start it; if disabled but running, stop it

## Verification

- [ ] `flutter analyze` passes
- [ ] With test mode + alerts on (radius ≥ simulated storm distance): background the app and confirm a notification arrives, tapping it opens the camera page
- [ ] Confirm cooldown: a burst of simulated strikes produces one audible alert, with the notification updating silently afterward
- [ ] Swipe the app away from recents and confirm alerts continue
- [ ] Toggle alerts off and confirm the persistent notification disappears and no further alerts arrive
- [ ] Reboot the device with alerts enabled and confirm monitoring resumes
