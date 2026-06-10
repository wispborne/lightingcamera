# Proposal: Strike History Seeding

## Problem

When the app's lightning map (or camera overlay) opens, it starts empty and only
fills as new strikes arrive — during a slow storm the user stares at a blank map
for minutes even though the relay saw plenty of strikes moments ago. The web map
solved this for itself with a private rolling backlog inside `web.js`, but that
buffer is invisible to the app server: app clients get nothing on connect.

## Proposed Solution

Promote the backlog into a single shared **strike history** owned by the relay
process:

- The relay keeps every decoded strike from the last **5 minutes** (matching the
  display window on both clients) in one rolling buffer, capped by count so a
  worldwide peak can't grow memory unbounded.
- The buffer is **snapshotted to disk** periodically and on shutdown, and loaded
  back on start, so a quick restart (deploy, crash, reboot) doesn't blank every
  client's map. Strikes older than the window are dropped on load, so a long
  outage simply starts empty.
- The history is **queryable by bounding box**, reusing the existing `inBox`
  helper.
- **App server** (`server.js`): when a client subscribes with a center + radius,
  the relay replies with a `{type:'backlog', strikes:[...]}` message containing
  the history filtered to that client's box, before live strikes resume.
- **Web server** (`web.js`): drops its private buffer and serves its existing
  backlog message from the shared history instead (queried with no box — the
  whole world). The browser page already consumes it; no frontend change.
- **App** (`LightningService`): handles the new `backlog` message by replacing
  its strike list with the replayed strikes, so the map and camera overlay are
  seeded the moment a page opens. Older relays never send `backlog`, and older
  apps ignore unknown message types, so both directions stay compatible.

## Scope

- New shared history module in `relay/src/`, including the snapshot file
  (load on start, periodic save, save on shutdown).
- `server.js`: send a box-filtered backlog on every subscription.
- `web.js`: replace the private backlog with queries against the shared history.
- `relay/index.js` + `config.default.yaml`: wire the history in, move the size
  cap out of the `web` section into a shared `history` section.
- `lib/lightning/lightning_service.dart`: parse `backlog` and seed the strike
  list.

## Non-Goals

- No durable archive — the snapshot exists only to bridge restarts. Anything
  older than the 5-minute window is gone forever; there is no playback or
  long-term storage.
- No change to the lazy upstream: the history only fills while at least one
  subscriber holds the upstream open. The first subscriber after an idle period
  still starts from an empty (or partial) history, exactly like the web map today.
- No HTTP query endpoint — the history is reachable only through the existing
  websocket protocols.
- No change to the web frontend (`relay/web/`).
