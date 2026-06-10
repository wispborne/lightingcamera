# Design: Lightning Web Map

## Overview

The relay already holds one upstream Blitzortung connection carrying **every strike
worldwide** — `server.js` merely filters per-client boxes before fanning out. The web
map is therefore a second, unfiltered front on plumbing that already exists:

```
 Blitzortung ──▶ RELAY PROCESS ──┬─▶ :8787 app server (key auth, box filter)   ← unchanged
                 (one upstream)  └─▶ :8788 web server (static page + world WS) ← new
                                          ▲
                       Caddy (TLS) ─ tinyauth (forward_auth) ─ browser
```

Everything lands in `relay/` — no Flutter changes.

## Key Decisions

1. **Web server inside the relay process** (`relay/src/web.js`), not a separate
   service. It taps the decoded strike stream in-process — no second websocket hop, no
   relay key, no duplicated reconnect logic. `web.enabled: false` turns it off
   entirely.
2. **Auth at the proxy, not the relay.** The web port binds `127.0.0.1` by default and
   is only reachable through Caddy, where tinyauth's `forward_auth` gates every request
   (including the websocket upgrade). The relay's key system stays app-only.
3. **Vanilla JS + Leaflet, no build step.** Three static files plus a vendored Leaflet
   copy (`relay/web/vendor/leaflet/`) so the page loads with zero external dependencies
   except map tiles. Dark CARTO basemap (`dark_all`, free for non-commercial use, with
   attribution) for the lightningmaps.org look.
4. **Custom canvas overlay for strikes**, not one Leaflet marker per strike. A global
   5-minute window can hold tens of thousands of strikes during active weather;
   thousands of DOM markers would crawl. One `<canvas>` redrawn per tick draws 20k dots
   in a few milliseconds.
5. **Same visual constants as the app** (`lightning_map_page.dart` /
   `lightning_service.dart`): 5-minute display window, opacity 1 → 0.05, HSV hue
   240 (new, blue) → 0 (old, red), thunder front at 343 m/s capped at 15 miles
   (24 140 m) with border alpha fading to 0 at the cap.

## Relay Changes

### Shared subscriber gauge (`relay/src/subscribers.js` — new)

`server.js` currently keeps its own `subscriberCount` to drive the lazy upstream
connect/disconnect. Web viewers must also wake the upstream, so the count moves to a
tiny shared module:

```js
export function makeSubscriberGauge({ onFirst, onLast }) {
  let count = 0;
  return {
    add()    { if (++count === 1) onFirst?.(); },
    remove() { if (--count === 0) onLast?.(); },
  };
}
```

`index.js` creates one gauge and passes it to both servers. `server.js` swaps its
internal counter for `gauge.add()` / `gauge.remove()` (same call sites: first
subscription, close while subscribed).

### Web server (`relay/src/web.js` — new)

One HTTP server on `config.web.host:config.web.port` doing two jobs:

**Static files** — a small hand-rolled handler (no express): whitelist of extensions
(`.html .js .css .png .svg`), files resolved against `relay/web/`, and a
resolved-path-starts-with-root check so `..` traversal is impossible. `/` serves
`index.html`.

**Websocket (`/ws`)** — `WebSocketServer` on the same HTTP server:

- On connection: `gauge.add()`, send `{type:'backlog', strikes:[...]}` from the rolling
  buffer, then stream live strikes. No auth message expected; inbound messages are
  ignored.
- On close: `gauge.remove()`.
- Same ping/pong liveness sweep as `server.js` (reuse the pattern, `heartbeatMs` from
  `config.web`), including the app-level `{type:'ping'}`.
- `broadcast(strike)` sends `{type:'strike', lat, lon, time}` to every open socket —
  no box check.

**Backlog buffer** — kept inside `web.js`: an array of recent strikes, pushed on every
broadcast, pruned to the 5-minute display window, and capped at
`config.web.backlogMaxStrikes` (drop oldest) so a worldwide lightning peak can't grow
memory unbounded. The buffer fills only while the upstream is connected — an empty
backlog right after relay start is expected and fine.

### Wiring (`relay/index.js`)

- Create the gauge with the existing `connectUpstream` / `disconnectUpstream` as
  `onFirst` / `onLast`.
- Start the web server when `config.web.enabled`.
- The upstream strike callback now feeds both fronts:
  `server.broadcast(strike); web?.broadcast(strike);`
- Shutdown closes the web server too.

### Config (`relay/config.default.yaml`)

```yaml
# Browser-facing world map server. Runs on its own port so Caddy + tinyauth can
# gate it separately from the app relay. Binds localhost — only the proxy reaches it.
web:
  enabled: false        # opt-in per deployment
  host: 127.0.0.1
  port: 8788
  heartbeatMs: 30000
  backlogMaxStrikes: 20000
```

Default **disabled** so existing deployments are untouched until configured (spec
A7.4).

## Frontend (`relay/web/`)

```
relay/web/
├── index.html          # full-screen map div, status pill, thunder toggle
├── app.js              # websocket client, strike store, canvas overlay
├── style.css           # dark theme, controls
└── vendor/leaflet/     # leaflet.js, leaflet.css, marker images (vendored)
```

### Strike store and rendering

- `strikes`: array of `{lat, lon, time}`; backlog seeds it, live strikes append, a
  pruning pass drops entries older than 5 minutes (spec A3.4).
- A custom Leaflet layer owns a full-size canvas positioned over the map. Each redraw:
  clear, then for every strike project `latLngToContainerPoint`, skip off-screen
  points, draw a dot with the age color/alpha ramp. Strikes younger than ~30 s get a
  small radial glow; older ones are flat dots (glow on 20k points is what kills canvas
  performance).
- **Redraw cadence:** 1 Hz when thunder circles are off (fades only need that, matches
  the app's ticker). When thunder circles are on, `requestAnimationFrame` throttled to
  ~15 fps so the 343 m/s front visibly sweeps. Map `move`/`zoom` events also trigger a
  redraw.
- Thunder circles draw on the same canvas: radius in meters → pixels via the map's
  meters-per-pixel at the strike's latitude; skip circles past the 15-mile cap.

### Geolocation

On load, `navigator.geolocation.getCurrentPosition`:

- success → center map at regional zoom (~9, the app's opening view) and draw a
  "you are here" dot (small DOM marker is fine — there's exactly one).
- denial/failure → stay at world view (zoom 2.5, centered mid-Atlantic), show a quiet
  one-line status, never re-prompt. Geolocation requires a secure context — satisfied
  because Caddy terminates TLS.

### Websocket client

- Connect to `wss://<host>/ws` (derive scheme from `location.protocol`).
- Handle `backlog` (replace store), `strike` (append), `ping` (ignore).
- On close: status pill flips to "reconnecting", exponential backoff 1 s → 30 s cap,
  reset on successful open. On reconnect the backlog replay repopulates anything
  missed.

### Controls

- **Thunder toggle**: a single button (top-right); state in
  `localStorage.thunderCircles`.
- **Status pill**: connected / reconnecting + strike count in the last 5 minutes.
- Dark UI matching the basemap; no other chrome.

## Deployment (`relay/README.md`)

Add a section with the Caddy + tinyauth pattern:

```caddyfile
map.example.com {
    forward_auth localhost:3000 {       # tinyauth
        uri /api/auth/caddy
        copy_headers Remote-User
    }
    reverse_proxy 127.0.0.1:8788        # websocket upgrade proxied automatically
}
```

Notes to include: tinyauth must be running and configured separately; the existing
relay websocket domain stays as-is (app keys, no tinyauth); browsers only grant
geolocation over HTTPS, which Caddy provides.

## File Changes

| File | Change |
|------|--------|
| `relay/src/subscribers.js` | New — shared subscriber gauge |
| `relay/src/web.js` | New — static server + world websocket + backlog buffer |
| `relay/src/server.js` | Use shared gauge instead of internal `subscriberCount` |
| `relay/index.js` | Create gauge, start web server, broadcast to both fronts |
| `relay/config.default.yaml` | Add `web` section |
| `relay/web/index.html` / `app.js` / `style.css` | New — map page |
| `relay/web/vendor/leaflet/*` | New — vendored Leaflet |
| `relay/README.md` | Caddy + tinyauth deployment section |

## Risks

- **Worldwide strike volume** — peaks of tens of strikes/second are normal. Mitigated
  by the canvas renderer, the backlog cap, and per-socket sends being tiny JSON. If a
  single slow browser backpressures, `ws` buffers per-socket; the heartbeat sweep reaps
  dead ones.
- **CARTO tile policy** — free tier is for non-commercial, low-traffic use; a private
  tinyauth'd page qualifies. Fallback is the standard OSM tile layer (one-line swap).
- **Misconfigured bind** — someone setting `web.host: 0.0.0.0` exposes an unauthenticated
  world feed. The default config comment spells out that auth is the proxy's job.
