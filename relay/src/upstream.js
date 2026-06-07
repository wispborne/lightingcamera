// Holds the single upstream connection to Blitzortung. Decodes each message and hands
// normalized {lat, lon, time} strikes to a callback. Reconnects with exponential backoff,
// rotating through the configured endpoints (ws1 -> ws7 -> ws8) on failure.

import WebSocket from 'ws';
import { parseStrikeMessage, normalizeStrike } from './decode.js';

export function startUpstream(config, log, onStrike) {
  const { urls, initMessage } = config.upstream;
  const { backoffMs, maxBackoffMs, heartbeatMs } = config.reconnect;

  let urlIndex = 0;
  let backoff = backoffMs;
  let ws = null;
  let heartbeat = null;
  let stopped = false;

  function connect() {
    if (stopped) return;
    const url = urls[urlIndex % urls.length];
    log.info(`upstream connecting to ${url}`);
    ws = new WebSocket(url);

    ws.on('open', () => {
      log.info(`upstream connected to ${url}`);
      backoff = backoffMs; // reset backoff on a good connection
      ws.send(JSON.stringify(initMessage));
      heartbeat = setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN) ws.ping();
      }, heartbeatMs);
    });

    ws.on('message', (data) => {
      const parsed = parseStrikeMessage(data.toString());
      const strike = parsed && normalizeStrike(parsed);
      if (strike) onStrike(strike);
    });

    ws.on('error', (err) => log.warn(`upstream error: ${err.message}`));

    ws.on('close', () => {
      clearInterval(heartbeat);
      if (stopped) return;
      urlIndex++; // rotate to the next endpoint
      log.warn(`upstream closed; reconnecting in ${backoff}ms`);
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, maxBackoffMs);
    });
  }

  connect();

  return {
    stop() {
      stopped = true;
      clearInterval(heartbeat);
      if (ws) ws.close();
    },
  };
}
