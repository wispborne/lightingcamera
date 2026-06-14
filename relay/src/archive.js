// Permanent archive of every recorded strike. Unlike the in-memory history (last
// few minutes, tuned to seed a client's map fast), this keeps everything forever
// in one SQLite file on disk so a storm can be queried long after it has passed.
//
// It is a passive sink: strikes are buffered and written in batches, and any
// failure here is logged but never touches live fan-out. Storage is compact —
// lat/lon are stored as integers scaled by COORD_SCALE (degrees * 1e4, ~11 m,
// well below Blitzortung's own accuracy), and the whole archive is one file you
// can copy or back up as a unit. Query it with any SQLite tool, or query-archive.js.
//
// Uses Node's built-in node:sqlite (needs Node 22.5+), imported lazily so the
// experimental-feature warning only appears when archiving is actually enabled.

import { fileURLToPath } from 'node:url';
import { dirname, isAbsolute, join } from 'node:path';

// Degrees -> stored integer. Read back as value / COORD_SCALE. Keep in sync with
// query-archive.js and the README.
export const COORD_SCALE = 10000;

// Relative db paths resolve against the relay directory, same as the snapshot.
const root = join(dirname(fileURLToPath(import.meta.url)), '..');

// A do-nothing archive returned when the database can't be opened, so callers
// never need null checks beyond the enable flag — the relay keeps running.
// `available: false` tells callers the DB isn't usable (so seeding/snapshot
// decisions can fall back), unlike a real archive that opened cleanly.
function noopArchive() {
  return { available: false, add() {}, flush() {}, recentSince: () => [], stop() {} };
}

export async function makeStrikeArchive({ dbPath, flushIntervalMs, batchSize, log }) {
  const path = isAbsolute(dbPath) ? dbPath : join(root, dbPath);

  let db;
  let insert;
  try {
    const { DatabaseSync } = await import('node:sqlite');
    db = new DatabaseSync(path);
    // WAL: crash-safe and lets the query script read while we write. NORMAL sync
    // is safe under WAL and avoids an fsync per commit.
    db.exec('PRAGMA journal_mode = WAL');
    db.exec('PRAGMA synchronous = NORMAL');
    db.exec(`
      CREATE TABLE IF NOT EXISTS strikes (
        t   INTEGER NOT NULL,
        lat INTEGER NOT NULL,
        lon INTEGER NOT NULL
      )
    `);
    db.exec('CREATE INDEX IF NOT EXISTS strikes_t ON strikes (t)');
    db.exec('PRAGMA user_version = 1');
    insert = db.prepare('INSERT INTO strikes (t, lat, lon) VALUES (?, ?, ?)');
    log?.info(`strike archive: writing to ${path}`);
  } catch (err) {
    log?.error(`strike archive: disabled, could not open ${path}: ${err.message}`);
    return noopArchive();
  }

  let buffer = [];

  // Write the buffered strikes in one transaction. Empty buffer is a no-op so an
  // idle relay never writes. On error we roll back and keep the relay alive; the
  // strikes stay buffered for the next attempt.
  function flush() {
    if (buffer.length === 0) return;
    try {
      db.exec('BEGIN');
      for (const s of buffer) {
        insert.run(
          s.time,
          Math.round(s.lat * COORD_SCALE),
          Math.round(s.lon * COORD_SCALE),
        );
      }
      db.exec('COMMIT');
      buffer = [];
    } catch (err) {
      try { db.exec('ROLLBACK'); } catch { /* nothing to roll back */ }
      log?.warn(`strike archive: flush failed, ${buffer.length} strikes still buffered: ${err.message}`);
    }
  }

  // Unref'd so the timer never keeps the process alive on its own (same as the
  // history snapshot timer).
  const timer = setInterval(flush, flushIntervalMs);
  timer.unref?.();

  return {
    available: true,
    add(strike) {
      buffer.push(strike);
      if (buffer.length >= batchSize) flush();
    },
    flush,
    // Strikes at or after `cutoffMs`, oldest first, in the live strike shape
    // ({lat, lon, time} in degrees). Used to seed the rolling history on startup.
    // Flushes first so anything buffered is included.
    recentSince(cutoffMs) {
      flush();
      try {
        const rows = db
          .prepare('SELECT t, lat, lon FROM strikes WHERE t >= ? ORDER BY t')
          .all(cutoffMs);
        return rows.map((r) => ({
          time: r.t,
          lat: r.lat / COORD_SCALE,
          lon: r.lon / COORD_SCALE,
        }));
      } catch (err) {
        log?.warn(`strike archive: could not read recent strikes: ${err.message}`);
        return [];
      }
    },
    stop() {
      clearInterval(timer);
      flush();
      try { db.close(); } catch { /* already closing down */ }
    },
  };
}
