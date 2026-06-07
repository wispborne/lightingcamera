// Client-facing websocket server. Each app connects, sends a subscription
// { lat, lon, radiusKm }, and then receives { lat, lon, time } strikes inside its box.
// TLS can be terminated here (config.server.tls) or by a reverse proxy in front.

import { readFileSync } from 'node:fs';
import { createServer as createHttp } from 'node:http';
import { createServer as createHttps } from 'node:https';
import { WebSocketServer } from 'ws';

import { clampRadiusKm, boxFromCenter, inBox } from './geo.js';

export function startServer(config, log) {
  const { host, port, tls } = config.server;
  const maxRadius = config.limits.maxBoxRadiusKm;

  const http = tls?.enabled
    ? createHttps({ cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) })
    : createHttp();

  const wss = new WebSocketServer({ server: http });

  wss.on('connection', (socket) => {
    socket.box = null; // no strikes until the client subscribes

    socket.on('message', (data) => {
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return; // ignore malformed subscriptions
      }
      if (typeof msg.lat === 'number' && typeof msg.lon === 'number') {
        const radius = clampRadiusKm(msg.radiusKm, maxRadius);
        socket.box = boxFromCenter(msg.lat, msg.lon, radius);
        log.debug(`client subscribed center=${msg.lat},${msg.lon} r=${radius}km`);
      }
    });

    socket.on('error', (err) => log.debug(`client error: ${err.message}`));
  });

  http.listen(port, host, () => {
    log.info(`relay listening on ${tls?.enabled ? 'wss' : 'ws'}://${host}:${port}`);
  });

  // Broadcast a strike to every subscribed client whose box contains it.
  function broadcast(strike) {
    const payload = JSON.stringify(strike);
    for (const socket of wss.clients) {
      if (socket.readyState === socket.OPEN && socket.box && inBox(strike, socket.box)) {
        socket.send(payload);
      }
    }
  }

  return { broadcast, close: () => wss.close() };
}
