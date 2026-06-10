# Design: Add Lightning Map

## Overview

Two deliverables, in dependency order:

1. A **relay service** (separate codebase, runs on the user's VPS) — the risky, prove-it-first piece.
2. The **Flutter map feature** — consumes the relay over a websocket.

```
 ws1.blitzortung.org          RELAY (user's VPS)              PHONE (Flutter)
 ┌──────────────────┐     ┌────────────────────────┐     ┌────────────────────┐
 │ {"a":111} init   │────▶│ decode custom payload  │────▶│ web_socket_channel │
 │ raw strike msgs  │  1  │ filter to client's box │  WS │ flutter_map (OSM)  │
 │ (LZW-ish coded)  │ conn│ fan out to clients     │     │ age-faded markers  │
 └──────────────────┘     └────────────────────────┘     │ geolocator = center│
        few-sec delay        you host & operate          └────────────────────┘
```

## The Relay Service

### Why a relay at all

Blitzortung's data policy requires third-party apps to pull from their own server, not
hit Blitzortung's websockets from every client. The relay is also simply better design:
one upstream connection with all reconnect/decode logic in one place, instead of on every
phone.

### Upstream protocol

- Connect to `wss://ws1.blitzortung.org/` (fallbacks: `ws7`, `ws8`).
- On open, send the init message `{"a":111}`.
- The server streams one message per strike. The payload values are **compressed with a
  custom dictionary scheme** (LZW-like) that must be run through a decode routine before
  the JSON is readable. Each decoded strike yields at least `{ time (ns since epoch),
  lat, lon }` plus per-station signal data we ignore.
- The decode routine is **unofficial and undocumented** — ported from community
  implementations (e.g. [SimonSchick/BlitzortungAPI](https://github.com/SimonSchick/BlitzortungAPI),
  [homeassistant-blitzortung](https://github.com/mrk-its/homeassistant-blitzortung)). It
  can break if Blitzortung changes the format; the mitigation is that it lives in one
  server we control, not in shipped app binaries.

### Client-facing protocol

- App opens a websocket to the relay and sends its bounding box (a lat/lon rectangle
  around the user's location + a radius).
- Relay forwards only strikes within that box as small JSON messages:
  `{ "lat": <deg>, "lon": <deg>, "time": <ms epoch> }`.
- Relay handles upstream reconnect/backoff transparently so the client never sees it.

### Relay language — Node (decided)

The relay is written in **Node**. The reference decode routines are JavaScript, so the
single riskiest component (the custom payload decode) is reused from a known-working
version rather than hand-ported. Mature websocket libraries are available.

### Relay configuration

The relay reads all tunables from a **config file** (e.g. `config.json` / `.env` /
YAML — Node's choice) so nothing operational is hardcoded. At minimum:

| Key | Purpose |
|-----|---------|
| `upstream.urls` | Ordered Blitzortung websocket endpoints for failover (`ws1`, `ws7`, `ws8`) |
| `server.host` / `server.port` | What the client-facing websocket binds to |
| `server.tls` | Cert/key paths, or a flag indicating TLS is terminated by the reverse proxy |
| `limits.maxBoxRadiusKm` | Largest bounding box a client may request (abuse guard) |
| `maxStrikeAgeMs` | Server-side cap on how old a strike may be before it's dropped (a server-side rolling window, independent of the app's display window) |
| `reconnect.backoffMs` / `reconnect.heartbeatMs` | Upstream reconnect/backoff and keepalive timings |
| `log.level` | Logging verbosity |

The config is loaded once at startup; a sensible default file ships with the relay.

### Deployment

- Runs on the user's existing **VPS** (already available — no fly.io/managed host needed).
- Long-running process (systemd service or a container). Exposes one websocket port,
  ideally behind TLS (`wss://`) via the VPS's reverse proxy.
- The app needs the relay URL — store it as a constant / build config for now (a settings
  field could come later).

## The Flutter Feature

### Dependencies (`pubspec.yaml`)

- `flutter_map` — OpenStreetMap tiles, no API key, fits the non-commercial use.
- `latlong2` — `LatLng` type used by `flutter_map`.
- `geolocator` — device GPS for the map center and the bounding-box request.
- `web_socket_channel` — websocket client to the relay.

### Location & permissions

- Request location permission at runtime via `geolocator`.
- Add `ACCESS_FINE_LOCATION` (and coarse) to `AndroidManifest.xml`.
- On the map page: get current position → center the map → compute the bounding box to
  send to the relay. Handle permission-denied gracefully (show a prompt, fall back to a
  default center).

### Strike state

Follow the existing **signals singleton** pattern (like `imageCacheManager` and
`settingsManager`):

```
lib/lightning/
├── lightning_service.dart   # singleton: relay WS connection + strike list signal
└── lightning_map_page.dart  # flutter_map UI
```

- `lightningService` holds a `listSignal<Strike>` of recent strikes.
- Incoming relay messages append to the list; strikes older than a **configurable rolling
  window** (default a few minutes) are pruned. Start as a single named constant; it can be
  surfaced as a user setting via the existing `settingsManager` later. This display window
  is separate from the relay's server-side `maxStrikeAgeMs`.
- A `Strike` is a small model: `{ LatLng position, DateTime time }`.

### Map UI (`lightning_map_page.dart`)

- `flutter_map` with an OSM tile layer, centered on the user, a "you are here" marker.
- A `MarkerLayer` driven by the strike signal; each marker's **opacity fades with age**
  (newest brightest) so storm motion reads visually with no prediction math.
- Connect the relay websocket on page open, disconnect on dispose (mirrors how the camera
  page manages its stream lifecycle).

### Navigation (`main.dart` + camera page)

- Add `Pages.map = "map"` and a `/map` GoRoute as a child of `/`, matching the existing
  gallery/settings routes.
- Add an entry point on the camera page (an icon near the existing settings gear) to push
  the map route.

## Key Decisions

1. **Relay on the user's own VPS** — required by Blitzortung policy and already available.
1. **Node relay, config-file driven** — reuses the JS decode routine; all tunables
   (upstream endpoints, ports, limits, ages, log level) live in a config file, nothing
   hardcoded.
2. **flutter_map + OSM over Google/Mapbox** — free, no API key, no billing, aligns with a
   non-commercial app.
3. **Signals singleton for strike state** — consistent with `imageCacheManager` /
   `settingsManager`; no new state paradigm.
4. **Fade-by-age markers instead of prediction** — delivers a sense of motion for free and
   keeps v1 small; computed approach vectors are deferred.
5. **Prove the relay decode first** — a standalone script that prints decoded
   `{lat, lon, time}` is the go/no-go test before any UI work.

## Risks

- **Decode routine breakage** — unofficial format; isolated to the relay to limit blast
  radius. (See relay protocol above.)
- **Blitzortung policy compliance** — own-server requirement satisfied by the VPS relay;
  app stays free / non-commercial.
- **Feed latency (few seconds)** — fine for a map; explicitly not used for shutter timing.
- **GPS permission denial** — must degrade gracefully to a default center.
