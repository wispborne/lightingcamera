# Spec: Lightning Web Map

## Overview

A browser page, served by the relay, showing live worldwide lightning on a full-screen
map with age-faded strikes, the visitor's GPS position, and optional thunder wave
circles.

## Requirements

### R1 — World strike feed

The relay MUST expose a websocket on the web port that streams every decoded strike
worldwide, with no bounding-box filter and no relay-key authentication.

- **A1.1** A client connected to the web websocket receives `{type:'strike', lat, lon,
  time}` for strikes on any continent, not just near the viewer.
- **A1.2** Strikes older than the relay's `maxStrikeAgeMs` are never sent.
- **A1.3** The web websocket accepts connections without an auth message; the first
  server message arrives without the client sending anything.

### R2 — Backlog replay

On connect, the relay MUST send the strikes it has seen within the display window so
the map starts populated.

- **A2.1** A client connecting while strikes are flowing receives a
  `{type:'backlog', strikes:[...]}` message before (or immediately after) live strikes.
- **A2.2** Backlog entries older than the 5-minute display window are excluded.
- **A2.3** An empty backlog (relay just started or upstream idle) is valid: the message
  may be omitted or contain an empty list, and the page handles both.

### R3 — Map page

The page MUST render a full-screen world map in a dark style with live strikes.

- **A3.1** The map is pannable/zoomable across the whole world (zoom out to world view).
- **A3.2** New strikes appear within a few seconds of detection.
- **A3.3** Each strike fades over 5 minutes: opacity from 1.0 down to invisible and
  color ramping blue (new) → red (old), matching the app's look.
- **A3.4** Strikes older than 5 minutes are removed from the page's memory, so a
  long-open tab does not grow unbounded.

### R4 — Visitor location

The page MUST show the visitor's GPS position when available.

- **A4.1** On load, the page requests browser geolocation; on success it centers the
  map on the visitor at a regional zoom and shows a "you are here" marker.
- **A4.2** On denial or failure, the map falls back to a world view with no marker and
  no error spam — a quiet status note at most.

### R5 — Thunder wave circles

The page MUST offer a toggle that draws an expanding circle per strike representing
the thunder front.

- **A5.1** Circle radius grows at 343 m/s from the strike time, capped at 15 miles
  (24,140 m), after which the circle disappears — same constants as the app.
- **A5.2** The circle's border fades as it expands (full opacity at the strike, fully
  transparent at the cap).
- **A5.3** The toggle state persists across page reloads (localStorage).

### R6 — Connection resilience

The page MUST stay useful across network blips.

- **A6.1** The page shows a connection indicator (connected / reconnecting).
- **A6.2** On socket close, the page reconnects with exponential backoff (1 s → 30 s
  cap) and resets backoff after a successful connection.
- **A6.3** Relay `{type:'ping'}` keepalives are consumed silently.

### R7 — Deployment behind Caddy + tinyauth

The web port MUST be deployable behind a forward-auth proxy without relay changes.

- **A7.1** Default bind is `127.0.0.1` so the port is unreachable except through the
  proxy; host/port/enabled are configurable.
- **A7.2** Websocket upgrade works through Caddy's `reverse_proxy`.
- **A7.3** The repository documents a working Caddyfile snippet with tinyauth
  `forward_auth` in front of the web port.
- **A7.4** With `web.enabled: false`, the relay behaves exactly as today.
