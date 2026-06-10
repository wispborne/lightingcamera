// Lightning relay entry point: load config, start the client-facing server, then
// connect upstream to Blitzortung only when at least one client is subscribed.

import { loadConfig, makeLogger } from './src/config.js';
import { startServer } from './src/server.js';
import { startUpstream } from './src/upstream.js';

const config = loadConfig();
const log = makeLogger(config.log.level);

let upstream = null;

function connectUpstream() {
  upstream = startUpstream(config, log, (strike) => {
    if (Date.now() - strike.time > config.maxStrikeAgeMs) return;
    server.broadcast(strike);
  });
}

function disconnectUpstream() {
  if (upstream) {
    upstream.stop();
    upstream = null;
  }
}

log.info('starting lightning relay');
const server = startServer(config, log, {
  onFirstSubscriber() {
    log.info('first subscriber connected, starting upstream');
    connectUpstream();
  },
  onLastSubscriber() {
    log.info('last subscriber disconnected, stopping upstream');
    disconnectUpstream();
  },
});

function shutdown(signal) {
  log.info(`received ${signal}, shutting down`);
  disconnectUpstream();
  server.close();
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
