# Spec: Relay Strike History

One in-memory rolling buffer of recent strikes, shared by both relay fronts, used
to seed a client's map the moment it connects.

## Requirements

### R1 — Rolling window

- R1.1: The relay SHALL retain every decoded upstream strike for 5 minutes
  (matching the client display window), measured against the strike's own
  timestamp.
- R1.2: The history SHALL be capped at a configurable maximum strike count
  (default 20 000); when full, the oldest strikes are dropped first.
- R1.3: The history fills only while the upstream feed is connected; on start it
  is seeded from the snapshot file (R6), or empty when no usable snapshot exists.

### R2 — Bounding-box query

- R2.1: The history SHALL answer queries for all retained strikes inside a
  lat/lon bounding box, using the same box semantics as live filtering (`inBox`).
- R2.2: A query with no box SHALL return all retained strikes (the web map's
  worldwide view).
- R2.3: Expired strikes SHALL never appear in query results, even if a prune
  hasn't run since they aged out.

### R3 — App seeding

- R3.1: After an authenticated app client sends a subscription (center + radius),
  the server SHALL send one `{type:'backlog', strikes:[{lat, lon, time}, ...]}`
  message containing the history filtered to that client's box.
- R3.2: A backlog SHALL be sent on every subscription message, including
  re-subscriptions after the user moves, so the replayed window always matches
  the current box.
- R3.3: On receiving `backlog`, the app SHALL replace its strike list with the
  replayed strikes (pruned to the display window), then continue appending live
  strikes.
- R3.4: An empty history SHALL produce `{type:'backlog', strikes:[]}` — clients
  treat it the same as any other backlog.

### R4 — Web seeding

- R4.1: The web server SHALL seed each new viewer from the shared history
  (worldwide query) using its existing `backlog` message; observable behavior on
  the page is unchanged.

### R5 — Compatibility

- R5.1: Apps that don't understand `backlog` SHALL be unaffected (they already
  ignore unknown message types).
- R5.2: Apps connected to an older relay that never sends `backlog` SHALL behave
  exactly as today.

### R6 — Persistence across restarts

- R6.1: The relay SHALL snapshot the history to a single file on disk
  periodically while strikes are arriving, and once more on clean shutdown.
- R6.2: On start, the relay SHALL load the snapshot, drop strikes older than the
  5-minute window, and seed the history with the remainder.
- R6.3: Snapshot writes SHALL be atomic (write to a temp file, then rename) so a
  crash mid-write can never leave a torn file.
- R6.4: A missing, unreadable, or corrupt snapshot SHALL be logged and treated as
  an empty history — never a startup failure.
- R6.5: The snapshot path SHALL be configurable; the default lives next to the
  relay's config and is gitignored.

## Acceptance Criteria

- Opening the app map mid-storm shows the last 5 minutes of nearby strikes within
  a second of subscribing, not just strikes arriving after open.
- Moving far enough to re-subscribe replays the history for the new box without
  duplicating strikes already shown.
- A fresh web tab still opens populated, with no change to `relay/web/`.
- Restarting the relay within the window and reconnecting shows the pre-restart
  strikes on both clients; restarting after more than 5 minutes idle starts
  empty with no errors.
- Deleting or corrupting the snapshot file logs a warning and the relay starts
  normally with an empty history.
