// Holds the single upstream connection to Blitzortung. Decodes each message and hands
// normalized {lat, lon, time} strikes to a callback. Reconnects with exponential backoff,
// rotating through the configured endpoints (ws1 -> ws7 -> ws8) on failure.

import WebSocket from 'ws';
import { parseStrikeMessage, normalizeStrike } from './decode.js';

export function startUpstream(config, log, onStrike) {
  const { urls, initMessage } = config.upstream;
  const { backoffMs, maxBackoffMs, heartbeatMs } = config.reconnect;

  // The worldwide feed never goes quiet for long, so a stretch this long with no
  // messages means the feed is stalled even if the connection itself looks fine.
  const silentMs = config.reconnect.silentMs ?? 120000;

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

    // Liveness has two layers: a pong must answer each ping (catches a dead
    // connection the TCP stack hasn't noticed), and messages must keep arriving
    // (catches a healthy connection whose feed has stopped). Either failing
    // terminates the socket, and the close handler reconnects on the next URL.
    let alive = true;
    let lastMessageAt = Date.now();
    ws.on('pong', () => { alive = true; });

    ws.on('open', () => {
      log.info(`upstream connected to ${url}`);
      backoff = backoffMs; // reset backoff on a good connection
      alive = true;
      lastMessageAt = Date.now();
      ws.send(JSON.stringify(initMessage));
      heartbeat = setInterval(() => {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        if (!alive) {
          log.warn('upstream stopped answering pings; reconnecting');
          ws.terminate();
          return;
        }
        if (Date.now() - lastMessageAt > silentMs) {
          log.warn(`upstream sent nothing for ${silentMs}ms; reconnecting`);
          ws.terminate();
          return;
        }
        alive = false;
        ws.ping();
      }, heartbeatMs);
    });

    ws.on('message', (data) => {
      lastMessageAt = Date.now();
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
