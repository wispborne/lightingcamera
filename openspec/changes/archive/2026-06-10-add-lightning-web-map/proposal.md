# Proposal: Lightning Web Map

## Problem

The lightning map lives only inside the Android app. There is no way to glance at storm
activity from a desktop browser, share the view with friends on the private server, or
watch the whole world at once — the app's relay subscription is capped at a 250 km
bounding box around the user. Public sites like lightningmaps.org do this, but the
project already runs its own Blitzortung relay and shouldn't depend on (or hammer) a
third-party page.

## Proposed Solution

Add a browser-based world lightning map served by the existing Node relay:

- A new **web server** inside the relay process, on its own port (default `8788`,
  separate from the app-facing `8787`), serving a static map page and a websocket that
  streams **all strikes worldwide** — no bounding-box filter.
- The page shows a full-screen dark map (like lightningmaps.org) with:
  - the visitor's GPS location (browser geolocation) as a "you are here" marker,
  - live strikes everywhere in the world, fading out over the same 5-minute window and
    blue-to-red age ramp the app uses,
  - an optional **thunder wave** overlay: an expanding circle per strike at the speed of
    sound (343 m/s, capped at 15 miles), same as the app's thunder circles.
- On connect, the relay replays a short backlog of recent strikes so the map is not
  empty for the first few minutes.
- The port is **not** protected by relay keys. It binds to localhost and sits behind
  Caddy with tinyauth (forward auth) in front — authentication happens at the proxy.
  Deployment docs include the Caddyfile + tinyauth snippet.

## Scope

- New `web` module in `relay/` (server + static frontend assets).
- Shared subscriber counting so web viewers also wake the lazy upstream connection.
- Relay config additions (`web.enabled`, `web.host`, `web.port`).
- Deployment documentation (Caddy + tinyauth example).

## Non-Goals

- No changes to the Flutter app.
- No historical strike archive or playback beyond the short in-memory backlog.
- No strike density heatmaps, detector-station data, or storm tracking.
- No user accounts in the relay itself — auth stays at the proxy (tinyauth).
- No public deployment; this remains a private, friends-only server.
