# Tasks: Strike Archive

## Config

- [x] Add an `archive` section to `relay/config.default.yaml`: `enabled: false`,
      `dbPath: strike-archive.db`, `flushIntervalMs: 5000`, `batchSize: 1000`, each
      commented (note the SSD path and the Node 22.5+ requirement)
- [x] Confirm the loaded config exposes `archive` (the loader merges defaults <-
      `config.yaml`); read values in `index.js` with `??` fallbacks like `history`

## Archive module

- [x] Create `relay/src/archive.js` with `makeStrikeArchive({ dbPath, flushIntervalMs, batchSize, log })`
- [x] Resolve `dbPath` like `history.js` (relative → relay root, absolute → as-is)
- [x] Dynamically `import('node:sqlite')` inside the factory so it's only loaded when
      enabled; open the DB, set `journal_mode = WAL` and `synchronous = NORMAL`
- [x] Create the `strikes` table and `strikes_t` index if absent; set `PRAGMA user_version = 1`
- [x] Prepare the insert statement once; store `lat`/`lon` as `round(deg * 10000)`,
      `t` as the strike's ms timestamp
- [x] Implement `add(strike)` (push to buffer; flush when buffer length ≥ batchSize)
- [x] Implement `flush()` as a single `BEGIN`/`COMMIT` transaction over the buffer;
      no-op when empty; on error, log + roll back, keep the relay alive
- [x] Add the `flushIntervalMs` timer, `unref()`'d, flushing only when strikes are buffered
- [x] Implement `stop()`: clear the timer, final `flush()`, close the DB
- [x] On any construction/open failure, log and return a no-op archive (all methods no-op)

## Wiring

- [x] In `relay/index.js`, construct `archive` only when `config.archive?.enabled`
      (else `null`), passing the resolved options
- [x] Call `archive?.add(strike)` in the upstream callback, right after `history.add(strike)`
- [x] Call `archive?.stop()` in `shutdown()` alongside `history.stop()`

## Seed history from archive

- [x] Add `recentSince(cutoffMs)` to the archive (flush, then return in-window
      strikes in `{lat, lon, time}` degree shape) and an `available` flag to both
      the real and no-op archives
- [x] Add an optional `seedStrikes` param to `makeStrikeHistory` that seeds the
      window (pruned to the display window) and skips the snapshot load
- [x] In `index.js`, construct the archive before the history; when the archive is
      usable, seed the history from `recentSince` and pass `snapshotPath: null`
      (skip the JSON snapshot); otherwise keep the snapshot path

## Query helper

- [x] Create `relay/query-archive.js`: open the configured DB read-only and print a
      summary (total count, earliest/latest time) when run with no args
- [x] Support `--since <iso> [--until <iso>]` for a time-range count
- [x] Support `--box <minLat,minLon,maxLat,maxLon>` (count, plus `--list` to print
      rows) honoring `--since/--until`; convert scaled ints back to degrees on output

## Docs & hygiene

- [x] Document the archive in `relay/README.md`: purpose, `archive` config, SSD path
      guidance, the schema + ×10000 scale factor, the query script, and the
      tens-of-GB/year growth estimate
- [x] Add `*.db`, `*.db-wal`, `*.db-shm` to `relay/.gitignore` (so a relative default
      path doesn't get committed)

## Verification

- [x] Enable archiving with a temp `dbPath`, run the relay through some strikes, and
      confirm `query-archive.js` reports a non-zero total and sensible time range
- [x] SIGINT the relay and confirm the final buffer is flushed (count includes the
      last strikes before shutdown)
- [x] Run a `--box` query and confirm only in-box strikes are returned and
      coordinates read back correctly (within ~11 m)
- [x] Point `dbPath` at a non-existent directory and confirm the relay logs an error,
      still starts, and still serves clients (archiving off)
- [x] With archiving disabled (default), confirm normal relay behavior and no
      `node:sqlite` experimental warning
- [x] With archiving enabled, restart and confirm the rolling history is seeded
      from the archive (recent strikes present, old ones excluded) and no
      `strike-history.json` is written
