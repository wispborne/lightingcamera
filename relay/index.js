// Lightning relay entry point: load config, start the client-facing server (and the
// browser map server if enabled), then connect upstream to Blitzortung and hold that
// connection open for the relay's whole lifetime so strike history keeps accumulating
// even with no clients watching.

import { loadConfig, makeLogger } from './src/config.js';
import { makeStrikeArchive } from './src/archive.js';
import { DISPLAY_WINDOW_MS, makeStrikeHistory } from './src/history.js';
import { startServer } from './src/server.js';
import { startUpstream } from './src/upstream.js';
import { startWeb } from './src/web.js';
import { makeSubscriberGauge } from './src/subscribers.js';

const config = loadConfig();
const log = makeLogger(config.log.level);

// Permanent on-disk record of every recorded strike, alongside the rolling
// history. Opt-in (needs Node 22.5+ for node:sqlite); constructed only when
// enabled so node:sqlite is never imported otherwise. Failures fail soft.
const archive = config.archive?.enabled
  ? await makeStrikeArchive({
      dbPath: config.archive?.dbPath ?? 'strike-archive.db',
      flushIntervalMs: config.archive?.flushIntervalMs ?? 5000,
      batchSize: config.archive?.batchSize ?? 1000,
      log,
    })
  : null;

// Rolling last-5-minutes of strikes, replayed to clients on subscribe so their
// maps start populated. When the archive is usable it is the authoritative record,
// so the window is seeded from it and the JSON snapshot is skipped; otherwise the
// snapshot seeds and persists the window. backlogMaxStrikes is the cap's old
// web-only name, kept as a fallback for deployment overrides that still set it.
const archiving = archive?.available === true;
const history = makeStrikeHistory({
  windowMs: DISPLAY_WINDOW_MS,
  maxStrikes: config.history?.maxStrikes ?? config.web?.backlogMaxStrikes ?? 20000,
  snapshotPath: archiving ? null : (config.history?.snapshotPath ?? 'strike-history.json'),
  snapshotIntervalMs: config.history?.snapshotIntervalMs ?? 10000,
  seedStrikes: archiving ? archive.recentSince(Date.now() - DISPLAY_WINDOW_MS) : undefined,
  log,
});

let upstream = null;

function connectUpstream() {
  upstream = startUpstream(config, log, (strike) => {
    if (Date.now() - strike.time > config.maxStrikeAgeMs) return;
    // History first, so a strike can't fall between a subscribe and its backlog
    // reply — it lands in one or the other.
    history.add(strike);
    archive?.add(strike);
    server.broadcast(strike);
    web?.broadcast(strike);
  });
}

function disconnectUpstream() {
  if (upstream) {
    upstream.stop();
    upstream = null;
  }
}

// Just a live count now — the upstream connection no longer rides on it. We keep the
// gauge so the servers can still log how many viewers are active.
const subscribers = makeSubscriberGauge({
  onFirst() {
    log.info('first subscriber connected');
  },
  onLast() {
    log.info('last subscriber disconnected');
  },
});

log.info('starting lightning relay');
const server = startServer(config, log, subscribers, history);
const web = config.web?.enabled ? startWeb(config, log, subscribers, history) : null;

// Connect upstream immediately and keep it open. History fills in the background so a
// map opened to check a flash you thought you saw already has the recent strikes.
connectUpstream();

function shutdown(signal) {
  log.info(`received ${signal}, shutting down`);
  disconnectUpstream();
  history.stop();
  archive?.stop();
  web?.close();
  server.close();
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
