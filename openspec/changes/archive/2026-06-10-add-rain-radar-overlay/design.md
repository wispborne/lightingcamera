# Design — Rain Radar Overlay

## Data source

RainViewer public weather maps API (verified live, free, key-less on 2026-06-10):

```
GET https://api.rainviewer.com/public/weather-maps.json
→ { "host": "https://tilecache.rainviewer.com",
    "radar": { "past": [ { "time": <unix>, "path": "/v2/radar/<id>" }, … ] } }
```

Tile URL for a frame (verified returns `image/png`):

```
{host}{path}/256/{z}/{x}/{y}/{color}/{options}.png
```

Constants: tile size `256`, color scheme `2` (Universal Blue), options `1_1`
(smoothing on, snow shown). Latest frame = last entry of `radar.past`.
`nowcast` is empty since RainViewer's January 2026 API cutback — ignore it.

**Zoom cap.** RainViewer only renders radar up to **zoom 7** for 256px tiles;
at zoom ≥ 8 it returns a single static "Zoom level not supported" placeholder
(verified byte-identical across tiles on 2026-06-10). Every map must set
`maxNativeZoom: 7` on the radar layer so the client requests z7 tiles and
upscales them for closer views instead of showing that placeholder. Exposed as
`RainRadarService.maxNativeZoom` on the Dart side; hard-coded in `relay/web`.

## New: `lib/lightning/rain_radar_service.dart`

Top-level singleton `rainRadarService`, mirroring `LightningService`'s shape:

- `acquire()` / `release()` ref-counting. Each map view (map page, mini map)
  acquires in `initState` and releases in `dispose`.
- While `refCount > 0` **and** `settingsManager.rainRadarEnabled`: fetch the
  index immediately, then every 5 minutes (`Timer.periodic`). An `effect()` on
  `settingsManager.rainRadarEnabledSignal` starts/stops polling on toggle.
- HTTP via `dart:io HttpClient` + `dart:convert` — no new pub dependency.
  10-second timeout; failures logged with `Fimber.e` and retried next tick.
- Exposes `ReadonlySignal<String?> tileUrlTemplate`:
  - `null` when no frame yet, setting off, or newest frame older than 30
    minutes (staleness guard, R5) — checked at each poll tick.
  - Otherwise the fully-formed flutter_map template, e.g.
    `https://tilecache.rainviewer.com/v2/radar/<id>/256/{z}/{x}/{y}/2/1_1.png`.

Keeping the URL assembly inside the service means swapping providers later
(if RainViewer goes away) touches one file.

## Settings (`lib/settings/settings_manager.dart`)

One new persisted bool, following the existing pattern exactly:

- Key `rain_radar_enabled`, signal `_rainRadarEnabled`, default **true**,
  getter `rainRadarEnabled`, signal getter `rainRadarEnabledSignal`,
  setter `setRainRadarEnabled(bool)`.

One setting drives both maps — no per-map or opacity knobs (explicit decision).

## Map page (`lib/lightning/lightning_map_page.dart`)

- `initState`: `rainRadarService.acquire()`; `dispose`: `release()`.
- Layer order: base OSM `TileLayer` → **radar layer** → `CircleLayer`
  (thunder) → `MarkerLayer`. Radar goes under strikes so markers stay crisp.
- Radar layer, only when template non-null and setting on:
  ```dart
  Opacity(opacity: 0.7, child: TileLayer(urlTemplate: template, userAgentPackageName: …))
  ```
  (flutter_map 8 has no TileLayer opacity param; wrapping in `Opacity` is the
  documented approach.) Read the template via `SignalBuilder` — not `Watch`,
  which is deprecated in this codebase.
- App bar: second `IconButton` next to the thunder toggle —
  `Symbols.rainy` (on: `colors.primary`, off: dimmed `onSurfaceVariant`),
  tooltip "Hide rain radar" / "Show rain radar", calls
  `settingsManager.setRainRadarEnabled(!enabled)`.
- Attribution: `Text('Radar © RainViewer', style: text.labelSmall)` inside the
  existing bottom status card row (right-aligned), visible only while the
  radar layer renders. Keeps the overlay count at one, per UI guidelines.

## Mini map (`lib/lightning/mini_map.dart`)

- Same radar `TileLayer` (wrapped in `Opacity(0.7)`) inserted between the base
  tile layer and the marker layer, gated on the same setting + non-null
  template via `SignalBuilder`.
- The widget's existing outer `Opacity` (mini-map opacity setting) already
  applies on top — no extra handling.
- `_MiniMapState.initState`/`dispose` acquire/release the service. No
  attribution on the 120dp thumbnail (R6 exemption).

## Frame-change behavior

When the poll finds a newer frame, `tileUrlTemplate` changes value;
flutter_map treats a changed `urlTemplate` as a new layer and reloads tiles.
At one frame per ~10 minutes this is cheap. Old-frame tiles remain valid on
RainViewer's cache long enough that there's no flash of missing data.

## Failure modes

| Condition | Behavior |
|---|---|
| Index fetch fails | Log, keep current template, retry in 5 min |
| Fetch keeps failing > 30 min | Template goes null → layer hides (R5) |
| Setting off | No polling, no layer, zero network cost |
| API removed entirely | Permanent fetch failure → maps look exactly as today |
