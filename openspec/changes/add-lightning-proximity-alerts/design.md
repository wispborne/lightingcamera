# Design: Lightning Proximity Alerts

## Approach

Run the existing `LightningService` inside a background isolate hosted by an Android **foreground service** (`flutter_background_service`). The service isolate gets its own relay connection sized to the alert radius, computes strike distance against the latest GPS fix, and posts notifications via `flutter_local_notifications`. The main app's UI-facing lightning connection is untouched.

Why a foreground service and not scheduled background work: lightning is a minutes-long event; WorkManager's 15-minute minimum interval is useless here. A foreground service is the only Android mechanism that keeps a websocket alive indefinitely, and it's honest with the user (persistent notification).

Why reuse `LightningService` rather than extract a shared relay client: the class is plain Dart with no UI dependencies — `signals`, `geolocator`, and `web_socket_channel` all work in a background isolate, and `settingsManager.init()` can run there too (shared preferences is isolate-safe for reads; the service only reads). Instantiating a second `LightningService` in the service isolate reuses auth, reconnect backoff, the stale-link watchdog, and test mode for free. The only change it needs is a per-strike event hook (see below).

## Key Decisions

| Decision | Choice | Why |
|---|---|---|
| Background mechanism | `flutter_background_service` foreground service, `autoStartOnBoot: true` | Persistent socket; restarts after reboot; well-maintained |
| Foreground service type | `dataSync` + `location` | It both holds a network connection and reads GPS; Android 14+ requires declared types |
| Notifications | `flutter_local_notifications`, two channels | "Monitoring" (min importance, silent, the mandatory persistent one) and "Lightning alerts" (high importance) |
| Strike delivery to alert logic | New `Stream<Strike> get strikeStream` on `LightningService` (broadcast `StreamController`, fed wherever `_strikes.add` happens) | Avoids diffing the `ListSignal`; main app ignores it |
| Subscription radius in the service | `alertRadiusKm + 20` km buffer | Smaller than the UI's 150 km box → less traffic; buffer keeps edge strikes from flapping in/out as the user moves between location fixes |
| Cooldown | 5 min; same notification id updated silently during cooldown; bypass once if a strike is ≤ half the distance of the last alerted strike | Spec R4 |
| Settings propagation to service isolate | Service invokes `settingsManager.init()` on start; main isolate sends `service.invoke('settingsChanged', {...})` on radius/key/URL/unit change; service re-reads prefs and reconnects | Signals don't cross isolates; explicit poke is simple and reliable |
| Distance display | All user-facing distances (radius slider, notification text) go through `formatDistanceKm(km, unitSystem)` from `lib/utils/units.dart` | The app already has a metric/imperial preference; hardcoding km would be inconsistent. The service isolate reads `unitSystem` from prefs the same way it reads the radius |
| Radius bounds | Reuse `SettingsManager.minStrikeDistanceKm` (5) and `maxStrikeDistanceKm` (100) | Same range the existing "Overlay strike distance" slider uses; keeps one source of truth |
| Permission flow | On toggle-on: request `POST_NOTIFICATIONS` (via `permission_handler`, already a dependency), verify location while-in-use already granted (camera overlay flow handles it), then start service | Deny → toggle reverts with a SnackBar |

## File Changes

| File | Change |
|---|---|
| `pubspec.yaml` | Add `flutter_background_service`, `flutter_local_notifications` |
| `android/app/src/main/AndroidManifest.xml` | Add `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `FOREGROUND_SERVICE_LOCATION`, `RECEIVE_BOOT_COMPLETED`; service declaration with `foregroundServiceType="dataSync|location"` |
| `lib/lightning/lightning_service.dart` | Add `strikeStream` (broadcast); no behavior change otherwise |
| `lib/lightning/alert_service.dart` (new) | Service entrypoint (`@pragma('vm:entry-point')`): init prefs + notifications, get last known position, start a local `LightningService` in test or live mode, listen to `strikeStream`, distance/bearing math, cooldown state, notification posting, `settingsChanged`/`stop` handlers |
| `lib/lightning/alert_service_controller.dart` (new) | Main-isolate side: configure `FlutterBackgroundService` (channels, boot start), `start()`/`stop()`, permission requests, `notifysettingsChanged()` |
| `lib/settings/settings_manager.dart` | Add `lightningAlertsEnabled` (default false), `alertRadiusKm` (default 15.0, clamped with the existing `minStrikeDistanceKm`/`maxStrikeDistanceKm` constants) with signals + setters |
| `lib/settings/settings_page.dart` | New "Alerts" section: toggle + radius slider, label/trailing formatted via `formatDistanceKm(km, unitSystem)`; toggle drives the controller; disabled state when no relay key and test mode off. Mirrors the existing "Overlay strike distance" slider, with a label that distinguishes alert radius from that display filter |
| `lib/main.dart` | On startup, if `lightningAlertsEnabled`, ensure service is configured/running (covers app-update and process-death cases); handle notification tap → already lands on `/` (camera) |

## Notification Content

Distance via `latlong2`'s `Distance` (already used), formatted with `formatDistanceKm(km, settingsManager.unitSystem)` so it honors the user's metric/imperial choice; bearing via `Distance.bearing()`, mapped to 8 compass points. Body example: `Lightning 8 km away to the northwest` (or `5 mi away` for an imperial user). Tap intent launches the app; no payload routing needed since camera is the home route.

## Edge Cases

- **No relay key & test mode off**: toggle shows a message and won't enable (spec R2).
- **Test mode on**: the service's `LightningService` instance runs the storm simulator around the last known location — full end-to-end verification without weather.
- **No location fix ever**: service stays up, persistent notification text switches to "Waiting for location…", no alerts (spec R5).
- **Two relay sessions, one key** (UI + service): assumed allowed by the relay. If it turns out to be rejected with `4002`, revisit — documented in the proposal as a risk.
- **User revokes notification permission while running**: alerts silently stop showing (Android drops them); the persistent notification also disappears and Android may stop the service — the toggle state re-syncs on next app open by checking `service.isRunning()`.

## UI Notes

Settings section follows the existing page's patterns (Material 3, 8dp grid, `colorScheme` colors, `SwitchListTile`-style rows). The radius slider shows the current value as `15 km` in the row's trailing text.
