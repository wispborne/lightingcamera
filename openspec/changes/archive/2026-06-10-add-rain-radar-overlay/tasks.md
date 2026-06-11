# Tasks — Rain Radar Overlay

- [x] Add `rain_radar_enabled` setting to `SettingsManager` (key, signal, getter, signal getter, setter; default `true`), following the existing persisted-bool pattern.
- [x] Create `lib/lightning/rain_radar_service.dart`: `rainRadarService` singleton with `acquire()`/`release()`, 5-minute index polling via `dart:io HttpClient`, 30-minute staleness guard, and a `ReadonlySignal<String?> tileUrlTemplate` assembling the RainViewer tile URL (size 256, color 2, options `1_1`).
- [x] Wire polling to the setting: an `effect()` on `rainRadarEnabledSignal` starts/stops the timer while acquired; no network activity when off or unacquired.
- [x] Map page: acquire/release the service in `initState`/`dispose`; insert the radar `TileLayer` (wrapped in `Opacity(0.7)`, read via `SignalBuilder`) between the base tiles and the thunder circles.
- [x] Map page: add the radar app-bar `IconButton` toggle (rainy icon, primary when on / dimmed when off, tooltips), persisting via `setRainRadarEnabled`.
- [x] Map page: show "Radar © RainViewer" (`labelSmall`) in the bottom status card while the radar layer is rendering.
- [x] Mini map: acquire/release the service; insert the same gated radar layer between base tiles and markers using `SignalBuilder`.
- [x] Web map (`relay/web`): add a "Radar" toggle (localStorage-persisted, default on) and a RainViewer `L.tileLayer` beneath the strike canvas, with the same 5-min refresh, 30-min staleness guard, and attribution.
- [x] Verify with `flutter analyze` (clean — only pre-existing `Watch` deprecations remain).
- [x] On-device check (manual): layer appears/disappears with the toggle on both maps, setting survives restart, airplane mode degrades to plain maps with no errors surfaced.
