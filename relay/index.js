// Lightning relay entry point: load config, start the client-facing server (and the
// browser map server if enabled), then connect upstream to Blitzortung only while at
// least one client — app or web viewer — is subscribed.

import { loadConfig, makeLogger } from './src/config.js';
import { DISPLAY_WINDOW_MS, makeStrikeHistory } from './src/history.js';
import { startServer } from './src/server.js';
import { startUpstream } from './src/upstream.js';
import { startWeb } from './src/web.js';
import { makeSubscriberGauge } from './src/subscribers.js';

const config = loadConfig();
const log = makeLogger(config.log.level);

// Rolling last-5-minutes of strikes, replayed to clients on subscribe so their
// maps start populated. backlogMaxStrikes is the cap's old web-only name, kept
// as a fallback for deployment overrides that still set it.
const history = makeStrikeHistory({
  windowMs: DISPLAY_WINDOW_MS,
  maxStrikes: config.history?.maxStrikes ?? config.web?.backlogMaxStrikes ?? 20000,
  snapshotPath: config.history?.snapshotPath ?? 'strike-history.json',
  snapshotIntervalMs: config.history?.snapshotIntervalMs ?? 10000,
  log,
});

let upstream = null;

function connectUpstream() {
  upstream = startUpstream(config, log, (strike) => {
    if (Date.now() - strike.time > config.maxStrikeAgeMs) return;
    // History first, so a strike can't fall between a subscribe and its backlog
    // reply — it lands in one or the other.
    history.add(strike);
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

const subscribers = makeSubscriberGauge({
  onFirst() {
    log.info('first subscriber connected, starting upstream');
    connectUpstream();
  },
  onLast() {
    log.info('last subscriber disconnected, stopping upstream');
    disconnectUpstream();
  },
});

log.info('starting lightning relay');
const server = startServer(config, log, subscribers, history);
const web = config.web?.enabled ? startWeb(config, log, subscribers, history) : null;

function shutdown(signal) {
  log.info(`received ${signal}, shutting down`);
  disconnectUpstream();
  history.stop();
  web?.close();
  server.close();
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
