# Tasks: Add Lightning Map

## Relay service (prove this first)

- [x] Scaffold the Node relay project (package.json, websocket dependency)
- [x] Spike: standalone Node script connects to `wss://ws1.blitzortung.org/`, sends `{"a":111}`, and prints decoded `{lat, lon, time}` to the console — the go/no-go test for the whole change
- [x] Port/verify the custom JS decode routine against live data; confirm coordinates land in plausible real-world locations
- [x] Add a config file (upstream URLs, host/port, TLS, `maxBoxRadiusKm`, `maxStrikeAgeMs`, reconnect/heartbeat timings, log level) with a shipped default; load it at startup
- [x] Add bounding-box filtering: accept a client's lat/lon box and forward only strikes inside it (clamped to `maxBoxRadiusKm`)
- [x] Build the client-facing websocket server: accept a box on connect, fan out matching strikes as `{ lat, lon, time }` JSON, drop strikes older than `maxStrikeAgeMs`
- [x] Add upstream reconnect/backoff (ws1 → ws7 → ws8, per config) so clients never see a drop
- [ ] Deploy to the VPS as a long-running service (systemd/container) behind TLS (`wss://`) via the reverse proxy
- [ ] Confirm the deployed relay streams live strikes to a test websocket client over `wss://`

## Flutter app

- [x] Add `flutter_map`, `latlong2`, `geolocator`, `web_socket_channel` to `pubspec.yaml` and run `flutter pub get`
- [x] Add location permissions (`ACCESS_FINE_LOCATION` / coarse) to `AndroidManifest.xml`
- [x] Create `lib/lightning/lightning_service.dart` — signals singleton holding a `listSignal<Strike>`, relay websocket connection, append-on-message, prune strikes past the configurable rolling window (named constant for now)
- [x] Create `lib/lightning/lightning_map_page.dart` — `flutter_map` + OSM tiles, "you are here" marker, `MarkerLayer` of strikes with opacity fading by age; connect relay on open, disconnect on dispose
- [x] Wire GPS: request permission via `geolocator`, center the map on current position, compute the bounding box sent to the relay, handle permission-denied with a default center
- [x] Update `lib/main.dart` — add `Pages.map` and the `/map` GoRoute under `/`
- [x] Update `lib/camera/camera_page.dart` — add a map entry-point icon near the settings gear
- [x] Test on device: permission flow, map centers on location, real strikes appear and fade by age, connection survives backgrounding the app (debug APK build verified; full on-device test requires a connected device + the deployed relay URL)
