# Tasks: Lightning Proximity Alerts

## Dependencies & Platform Setup

- [x] Add `flutter_background_service` and `flutter_local_notifications` to `pubspec.yaml` and run `flutter pub get`
- [x] Add manifest permissions: `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `FOREGROUND_SERVICE_LOCATION`, `RECEIVE_BOOT_COMPLETED`
- [x] Declare the background service in `AndroidManifest.xml` with `foregroundServiceType="dataSync|location"`

## Settings

- [x] Add `lightningAlertsEnabled` (bool, default false) and `alertRadiusKm` (double, default 15, clamped with the existing `minStrikeDistanceKm`/`maxStrikeDistanceKm` constants) to `SettingsManager` with signals, getters, setters, and persistence
- [x] Add an "Alerts" section to `SettingsPage`: enable toggle and radius slider (slider disabled while the toggle is off; value shown via `formatDistanceKm` so it respects the user's metric/imperial setting), with a label that distinguishes it from the existing "Overlay strike distance" filter
- [x] Block enabling when no relay key is set and test mode is off, with an explanatory message

## Strike Event Hook

- [x] Add a broadcast `strikeStream` to `LightningService`, emitting every strike added in `_onMessage` and the simulator callback

## Alert Service

- [x] Create `lib/lightning/alert_service_controller.dart`: configure `FlutterBackgroundService` (foreground mode, `autoStartOnBoot`, monitoring notification channel), with `start()`, `stop()`, and `notifySettingsChanged()`
- [x] Create `lib/lightning/alert_service.dart` with the `@pragma('vm:entry-point')` service entrypoint: init `Fimber`, `settingsManager`, and `flutter_local_notifications`; create the two notification channels
- [x] In the entrypoint, resolve a starting location (last known fix, falling back to "waiting for location" state) and start a service-local `LightningService` with `radiusKm = alertRadiusKm + 20`
- [x] Implement proximity check on `strikeStream`: distance + 8-point compass bearing from current fix, compare against `alertRadiusKm`; format the distance for the notification with `formatDistanceKm` using the unit system read from prefs
- [x] Implement alert notification posting with 5-minute cooldown: silent update of the same notification during cooldown, one-time bypass when a strike is ≤ half the last alerted distance
- [x] Handle `settingsChanged` (re-read prefs, reconnect with new radius) and `stop` messages in the service isolate
- [x] Keep the persistent monitoring notification text current: "Watching for lightning within NN km" / "Waiting for location…"

## Wiring

- [x] On settings toggle on: request `POST_NOTIFICATIONS` via `permission_handler`, revert the toggle with a SnackBar on denial, then start the service; on toggle off: stop the service
- [x] Push radius/relay-key/relay-URL/test-mode/unit-system changes to a running service via `notifySettingsChanged()`
- [x] In `main.dart`, re-sync on launch: if `lightningAlertsEnabled` but the service is not running, start it; if disabled but running, stop it

## Verification

- [x] `flutter analyze` passes (no new errors; remaining `Watch` infos are pre-existing)
- [ ] (Manual, on device) With test mode + alerts on (radius ≥ simulated storm distance): background the app and confirm a notification arrives, tapping it opens the camera page
- [ ] (Manual, on device) Confirm cooldown: a burst of simulated strikes produces one audible alert, with the notification updating silently afterward
- [ ] (Manual, on device) Swipe the app away from recents and confirm alerts continue
- [ ] (Manual, on device) Toggle alerts off and confirm the persistent notification disappears and no further alerts arrive
- [ ] (Manual, on device) Reboot the device with alerts enabled and confirm monitoring resumes
