// Shared rolling history of recent strikes. Both fronts seed new clients from it:
// the app server replays the client's bounding box on subscribe, the web map
// replays the whole world on connect. Snapshotted to disk so a quick relay
// restart doesn't blank everyone's map; entries older than the window are pruned
// on load, so a long outage simply starts empty.

import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, isAbsolute, join } from 'node:path';

import { inBox } from './geo.js';

// Strikes this old have fully faded on both clients, so history stops at the
// same window. Mirrors LightningService.displayWindow in the app.
export const DISPLAY_WINDOW_MS = 5 * 60 * 1000;

// Relative snapshot paths resolve against the relay directory, same as config.
const root = join(dirname(fileURLToPath(import.meta.url)), '..');

export function makeStrikeHistory({ windowMs, maxStrikes, snapshotPath, snapshotIntervalMs, seedStrikes, log }) {
  const path = snapshotPath
    ? (isAbsolute(snapshotPath) ? snapshotPath : join(root, snapshotPath))
    : null;

  // Strikes arrive in near-chronological order from one upstream, so age-pruning
  // from the front of a plain array is sufficient.
  const strikes = [];
  let dirty = false;

  function prune() {
    const cutoff = Date.now() - windowMs;
    let drop = 0;
    while (drop < strikes.length && strikes[drop].time < cutoff) drop++;
    if (drop > 0) strikes.splice(0, drop);
    if (strikes.length > maxStrikes) strikes.splice(0, strikes.length - maxStrikes);
  }

  // When the archive is enabled it is the authoritative record, so it seeds the
  // window directly and the JSON snapshot is skipped (caller passes snapshotPath
  // null). Falls back to the snapshot when there's no archive.
  if (Array.isArray(seedStrikes)) {
    for (const s of seedStrikes) {
      if (typeof s?.lat === 'number' && typeof s?.lon === 'number' && typeof s?.time === 'number') {
        strikes.push({ lat: s.lat, lon: s.lon, time: s.time, delay: typeof s.delay === 'number' ? s.delay : 0 });
      }
    }
    prune();
    log?.info(`strike history: seeded ${strikes.length} strikes from archive`);
  } else if (path && existsSync(path)) {
    try {
      const loaded = JSON.parse(readFileSync(path, 'utf8'));
      if (!Array.isArray(loaded)) throw new Error('not an array');
      for (const s of loaded) {
        if (typeof s?.lat === 'number' && typeof s?.lon === 'number' && typeof s?.time === 'number') {
          strikes.push({ lat: s.lat, lon: s.lon, time: s.time, delay: typeof s.delay === 'number' ? s.delay : 0 });
        }
      }
      prune();
      log?.info(`strike history: loaded ${strikes.length} strikes from snapshot`);
    } catch (err) {
      strikes.length = 0;
      log?.warn(`strike history: ignoring unreadable snapshot ${path}: ${err.message}`);
    }
  }

  // Synchronous on purpose: also called from the shutdown signal handler, where
  // the final write must land before process.exit. Temp-file-then-rename keeps
  // the previous snapshot intact if a crash interrupts the write.
  function save() {
    if (!path) return;
    prune();
    try {
      writeFileSync(path + '.tmp', JSON.stringify(strikes));
      renameSync(path + '.tmp', path);
      dirty = false;
    } catch (err) {
      log?.warn(`strike history: could not write snapshot ${path}: ${err.message}`);
    }
  }

  // Dirty flag means an idle relay rewrites nothing. Unref'd so the timer never
  // keeps the process alive on its own.
  const saveTimer = path ? setInterval(() => { if (dirty) save(); }, snapshotIntervalMs) : null;
  saveTimer?.unref?.();

  return {
    add(strike) {
      strikes.push(strike);
      dirty = true;
      prune();
    },
    /** Retained strikes inside the box, or all of them when no box is given. */
    query(box = null) {
      prune();
      return box ? strikes.filter((s) => inBox(s, box)) : [...strikes];
    },
    save,
    stop() {
      if (saveTimer) clearInterval(saveTimer);
      if (dirty) save();
    },
  };
}
