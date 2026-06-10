# Tasks: Lightning Web Map

## Relay backend

- [x] Create `relay/src/subscribers.js` with `makeSubscriberGauge({onFirst, onLast})`
- [x] Refactor `relay/src/server.js` to take the gauge and drop its internal `subscriberCount`
- [x] Add the `web` section to `relay/config.default.yaml` (enabled, host, port, heartbeatMs, backlogMaxStrikes), default disabled
- [x] Create `relay/src/web.js`: HTTP server with safe static-file handler serving `relay/web/`
- [x] Add the `/ws` websocket to `web.js`: gauge add/remove, backlog replay on connect, unfiltered `broadcast(strike)`, ping/pong heartbeat sweep
- [x] Add the rolling backlog buffer to `web.js`: push on broadcast, prune past 5 minutes, cap at `backlogMaxStrikes`
- [x] Wire `relay/index.js`: shared gauge for both servers, start web server when enabled, feed strikes to both fronts, close web server on shutdown
- [x] Verify the app-facing relay is unchanged: with `web.enabled: false`, behavior and config parsing match today's

## Frontend

- [x] Vendor Leaflet into `relay/web/vendor/leaflet/` (js, css, images)
- [x] Create `relay/web/index.html` and `style.css`: full-screen dark map, status pill, thunder toggle button
- [x] Create `relay/web/app.js`: Leaflet map with CARTO dark tiles and attribution, world-view default
- [x] Implement the websocket client: connect to `/ws`, handle backlog/strike/ping, reconnect with 1 s → 30 s backoff and a status pill state
- [x] Implement the strike store: backlog seed, live append, prune older than 5 minutes
- [x] Implement the canvas strike overlay: age-based color (hue 240 → 0) and opacity (1 → 0.05), glow only on strikes under ~30 s, redraw on map move/zoom
- [x] Implement the redraw cadence: 1 Hz baseline, ~15 fps while thunder circles are on
- [x] Implement thunder circles: 343 m/s expansion, 15-mile cap, border alpha fading to 0 at the cap, toggle persisted in localStorage
- [x] Implement geolocation: center + "you are here" marker on success, quiet world-view fallback on denial

## Verification & docs

- [x] Run the relay locally with `web.enabled: true` and open the page: strikes appear worldwide, fade over 5 minutes, backlog populates a fresh tab
- [x] Test reconnect: kill and restart the relay with the page open, confirm the pill shows reconnecting and recovery repopulates strikes
- [x] Test thunder circles against the app side-by-side for matching speed and cap
- [x] Add the Caddy + tinyauth deployment section to `relay/README.md` (Caddyfile snippet, localhost-bind warning, HTTPS-for-geolocation note)
