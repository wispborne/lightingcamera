# Design: Strike Archive

## Approach

A new `relay/src/archive.js` module owns a single SQLite database and exposes the
same shape the rest of the relay already expects from a sink: an `add(strike)` call
and a `stop()` for shutdown — deliberately mirroring `makeStrikeHistory` so the
wiring in `index.js` reads the same.

`index.js` already has one place where every recorded strike passes through (the
upstream callback that calls `history.add`). The archive hooks in right next to it:

```js
history.add(strike);
archive?.add(strike);   // new — buffered, flushed in batches
server.broadcast(strike);
web?.broadcast(strike);
```

The archive buffers strikes in a plain array and flushes them to SQLite in one
transaction, either on a timer or once the buffer hits the batch size. This is the
same "accumulate, then write periodically" rhythm as the history snapshot, just
with an append to a database instead of a full-file rewrite.

Storage is the built-in `node:sqlite` (`DatabaseSync`), so the relay gains no npm
dependencies. It's synchronous, which fits both the batched-transaction write and
the synchronous final flush on shutdown.

## Why this shape

- **A second sink, not a change to history.** The in-memory history is tuned for one
  job (seed a client's map fast) and is correct as-is. The archive is a different
  job (keep everything forever). Keeping them separate means neither compromises the
  other; the archive can fail or be disabled with zero effect on live behavior.
- **`node:sqlite`, lazily imported.** Querying is a first-class requirement, and a
  SQLite file is queryable by every SQLite tool with no work from us. Using the
  built-in keeps the dependency list at `ws` + `yaml`. Importing it only inside
  `makeStrikeArchive` (a dynamic `import('node:sqlite')`) means the experimental
  warning never prints when archiving is off.
- **Batched transactions.** One transaction per flush turns thousands of strikes
  into a handful of fsyncs. The user explicitly accepted non-real-time durability,
  so a few seconds of buffer is the right trade.

## Schema

```sql
CREATE TABLE IF NOT EXISTS strikes (
  t   INTEGER NOT NULL,   -- ms since Unix epoch
  lat INTEGER NOT NULL,   -- round(latitude  * 10000)  -> degrees * 1e4
  lon INTEGER NOT NULL    -- round(longitude * 10000)
);
CREATE INDEX IF NOT EXISTS strikes_t ON strikes (t);
PRAGMA user_version = 1;
```

- No explicit primary key — the implicit `rowid` is enough and keeps rows compact.
- `lat`/`lon` as scaled `INTEGER` instead of `REAL`: SQLite stores small integers as
  1–4 byte varints but reals always as 8 bytes, so this roughly halves coordinate
  storage. ×10 000 gives ~11 m resolution — well below Blitzortung's own location
  accuracy, so it's lossless in practice. Read back as `lat / 10000`.
- Index on `t` for time-range queries (the most likely visualization axis). Bounding
  -box filtering scans within a time range; acceptable for an offline/occasional
  query. A spatial index can be added later under a bumped `user_version` if needed.

### Connection pragmas

```sql
PRAGMA journal_mode = WAL;     -- crash-safe; lets a query read while we write
PRAGMA synchronous = NORMAL;   -- safe under WAL, far fewer fsyncs
```

WAL also means the query script can read the database while the relay is writing.

## Module API (`relay/src/archive.js`)

```
makeStrikeArchive({ dbPath, flushIntervalMs, batchSize, log }) -> {
  add(strike),   // push to buffer; flush if buffer >= batchSize
  flush(),       // write buffered strikes in one transaction (no-op if empty)
  stop(),        // clear timer, final flush, close db
}
```

- Path resolution mirrors `history.js`: relative → relay root, absolute → as-is.
- On construction: open the DB, set pragmas, create table/index, prepare the insert
  statement once. Wrap in try/catch — on failure, log and return a **no-op archive**
  (every method a no-op) so callers don't need null checks beyond the enable flag.
- `flush()` wraps the prepared insert in `db.exec('BEGIN')` … `COMMIT`, iterating the
  buffer; on error, log and roll back, keep the relay alive.
- A `setInterval(flushIntervalMs)` timer, `unref()`'d (same as the snapshot timer) so
  it never holds the process open on its own.

## Querying (`relay/query-archive.js`)

A small standalone script (run with `node query-archive.js`) that opens the same DB
read-only and prints answers to the common questions, so "queryable" is true out of
the box and the user has working examples to build a visualization from later:

- no args → summary: total count, earliest/latest strike time.
- `--since <iso> [--until <iso>]` → count in a time range.
- `--box <minLat,minLon,maxLat,maxLon> [--since/--until]` → count (and optional
  `--list` of) strikes in a bounding box.

It reads the DB path from the same config loader, so it always targets the right
file. This is a convenience layer; any SQLite tool works too.

## Seeding the rolling history

The in-memory rolling history persists its 5-minute window to `strike-history.json`
so reconnecting maps start populated after a restart. Once the archive exists, that
snapshot is a redundant second copy of the same window. So when the archive is
enabled and opens cleanly, the history seeds its window from the archive instead
(`archive.recentSince(now − displayWindow)`) and the snapshot is neither read nor
written (`snapshotPath: null`). The archive is constructed before the history to make
this ordering possible. If the archive is disabled or failed to open
(`available === false`), the history falls back to the snapshot exactly as before, so
nothing regresses when archiving is off.

## File Changes

| File | Change |
|---|---|
| `relay/src/archive.js` (new) | The archive module: DB open, schema, batched writes, `recentSince` read for seeding, `available` flag, no-op fallback |
| `relay/src/history.js` | Optional `seedStrikes` param: seed the window from it (pruned) and skip the snapshot load |
| `relay/query-archive.js` (new) | Standalone read-only query helper (summary / time range / bounding box) |
| `relay/config.default.yaml` | New `archive` section: `enabled: false`, `dbPath`, `flushIntervalMs`, `batchSize`, all commented |
| `relay/src/config.js` | (Only if needed) ensure the `archive` section surfaces from the loaded config; defaults are read in `index.js` with `??` like `history` |
| `relay/index.js` | Construct `archive` when `config.archive?.enabled`; call `archive?.add(strike)` in the upstream callback; `archive?.stop()` in `shutdown()` |
| `relay/README.md` | Document the archive: what it is, the `archive` config, the SSD path, the schema/scale factor, and the query script |
| `relay/.gitignore` | Ignore the default local DB file(s) (`*.db`, `*.db-wal`, `*.db-shm`) if a relative default path is used |

## Config (shipped defaults)

```yaml
# Permanent archive of every recorded strike, written in batches to a SQLite
# database. Off by default; needs Node 22.5+ (uses the built-in node:sqlite).
archive:
  enabled: false
  # Where to keep the database. Use an absolute path on the external SSD.
  # A relative path resolves against the relay directory (and is gitignored).
  dbPath: strike-archive.db
  # Write buffered strikes at least this often (ms)...
  flushIntervalMs: 5000
  # ...or sooner once this many are buffered.
  batchSize: 1000
```

## Edge Cases

- **DB open fails (no SSD, bad path):** log error, return the no-op archive; relay
  serves clients normally, archiving simply off (spec R6.1).
- **Flush fails mid-run (disk full, SSD yanked):** log, roll back the transaction,
  keep the relay alive; the next flush retries (spec R6.2).
- **Disabled (default):** `index.js` never constructs the archive, so `node:sqlite`
  is never imported and no experimental warning prints (spec R6.3).
- **Clean shutdown:** `archive?.stop()` runs before `process.exit(0)`, flushing the
  tail of the buffer (spec R2.4) — placed alongside the existing `history.stop()`.
- **Volume:** worldwide feed ≈ 1–2 M strikes/day; at ~16 B/row plus the time index,
  growth is on the order of tens of GB/year — fine for an external SSD. Documented in
  the README so it isn't a surprise.
