// Lightning relay entry point: load config, start the client-facing server, then
// connect upstream to Blitzortung and fan fresh strikes out to subscribed clients.

import { loadConfig, makeLogger } from './src/config.js';
import { startServer } from './src/server.js';
import { startUpstream } from './src/upstream.js';

const config = loadConfig();
const log = makeLogger(config.log.level);

log.info('starting lightning relay');
const server = startServer(config, log);

const upstream = startUpstream(config, log, (strike) => {
  // Drop strikes older than the server-side window before fanning out.
  if (Date.now() - strike.time > config.maxStrikeAgeMs) return;
  server.broadcast(strike);
});

function shutdown(signal) {
  log.info(`received ${signal}, shutting down`);
  upstream.stop();
  server.close();
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
