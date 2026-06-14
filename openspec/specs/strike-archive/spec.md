# Spec: Strike Archive

A permanent, compact, queryable record of every strike the relay receives, stored
in a single SQLite database on disk — separate from the in-memory rolling history.

## Requirements

### R1 — Capture

- R1.1: When enabled, the archive SHALL receive every strike that the relay records
  (the same strikes added to the in-memory history, after the upstream
  staleness filter), so the two stay consistent about what "recorded" means.
- R1.2: The archive SHALL store, per strike, its latitude, longitude, and
  timestamp (ms since the Unix epoch).
- R1.3: The archive SHALL be a passive sink: failures to capture or write a strike
  SHALL never affect live fan-out to app or web clients.

### R2 — Batched writes

- R2.1: Strikes SHALL be buffered in memory and written in batches, not one row per
  strike, using a single transaction per flush.
- R2.2: A flush SHALL occur when either a configurable time interval elapses or the
  buffer reaches a configurable batch size, whichever comes first.
- R2.3: An idle archive (no strikes buffered) SHALL perform no writes.
- R2.4: On clean shutdown, any buffered strikes SHALL be flushed before the process
  exits.
- R2.5: Losing strikes buffered since the last flush on a hard crash is acceptable;
  the archive does not guarantee real-time durability.

### R3 — Compact storage

- R3.1: Latitude and longitude SHALL be stored as integers scaled by a fixed factor
  (degrees × 10 000, ≈ 11 m resolution), not as floating-point, to keep rows small.
- R3.2: The entire archive SHALL live in a single database file so it can be copied,
  moved, or backed up as one unit.
- R3.3: The scale factor and column meanings SHALL be documented so a reader can
  reconstruct real coordinates.

### R4 — Queryable

- R4.1: The archive SHALL be a standard SQLite database readable by any SQLite tool
  without the relay running.
- R4.2: The schema SHALL support efficient time-range queries (an index on the
  timestamp column).
- R4.3: The change SHALL provide a standalone script that answers common questions
  against the archive: total count, earliest/latest strike, count within a time
  range, and count/listing within a latitude/longitude bounding box.
- R4.4: The schema SHALL carry a version marker (`PRAGMA user_version`) so future
  schema changes can be detected and migrated.

### R5 — Configuration

- R5.1: The archive SHALL be controlled by a new `archive` config section with at
  least: an enable flag, the database file path, the flush interval, and the batch
  size.
- R5.2: The archive SHALL be disabled by default in the shipped config; it is opt-in
  per deployment.
- R5.3: A relative database path SHALL resolve against the relay directory (matching
  the snapshot path); an absolute path (e.g. on the external SSD) SHALL be used
  as-is.

### R6 — Seeding the rolling history

- R6a.1: When the archive is enabled and usable, the relay SHALL seed the
  in-memory rolling history (the client-seeding window) from the archive on
  startup — the recent strikes within the display window — instead of from the
  JSON snapshot.
- R6a.2: When seeding from the archive, the relay SHALL NOT also read or write the
  JSON snapshot file, so the same window is not persisted in two places.
- R6a.3: If the archive is disabled, or enabled but failed to open, the relay
  SHALL fall back to the JSON snapshot exactly as before.
- R6a.4: Seeding SHALL exclude strikes older than the display window, the same as
  a snapshot load.

### R7 — Resilience

- R7.1: If the database cannot be opened (missing directory, unplugged SSD,
  permission error), the relay SHALL log the error and continue running with
  archiving disabled — never crash on startup.
- R7.2: An error during a flush SHALL be logged and SHALL NOT crash the relay; the
  archive may retain or drop the failed batch, but the relay keeps fanning out
  strikes.
- R7.3: Enabling the archive SHALL be the only thing that imports `node:sqlite`, so
  the experimental-feature warning never appears when archiving is off.

## Acceptance Criteria

- With archiving enabled, after running the relay through some strikes, the query
  script reports a non-zero total and a sensible earliest/latest time range.
- Stopping the relay (SIGINT/SIGTERM) flushes the final buffer — the count after a
  clean stop includes strikes received just before shutdown.
- A bounding-box query returns only strikes inside the box, and coordinates read
  back match the live feed to within the scale-factor resolution.
- Pointing the database path at a directory that doesn't exist logs an error and the
  relay still starts and serves clients (archiving simply off).
- With archiving disabled (default), the relay behaves exactly as today and prints
  no `node:sqlite` experimental warning.
- The database file size grows roughly in line with the documented per-row estimate
  (tens of GB per year of the worldwide feed), not orders of magnitude more.
