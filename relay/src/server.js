// Client-facing websocket server. Each app connects, authenticates with its key
// ({ "auth": "<key>" } as the first message), then sends a subscription
// { lat, lon, radiusKm }. Every message the relay sends back is tagged with a
// `type` so the protocol can grow without breaking older clients: { type:'ack' }
// on auth, { type:'strike', lat, lon, time } for strikes, { type:'ping' } as a
// keepalive. The server also pings each socket so half-open connections (common
// on mobile) get reaped instead of lingering.
// TLS can be terminated here (config.server.tls) or by a reverse proxy in front.

import { readFileSync } from 'node:fs';
import { createServer as createHttp } from 'node:http';
import { createServer as createHttps } from 'node:https';
import { WebSocketServer } from 'ws';

import { clampRadiusKm, boxFromCenter, inBox } from './geo.js';
import { makeAuthGate, trustedIp } from './auth.js';

// WebSocket close codes the app distinguishes. 4001 (bad key) and 4003 (banned)
// tell the app NOT to reconnect; the others are transient and it retries.
const CLOSE_AUTH_TIMEOUT = 4000;
const CLOSE_UNAUTHORIZED = 4001;
const CLOSE_SESSION_EXPIRED = 4002;
const CLOSE_BANNED = 4003;
const CLOSE_TOO_MANY = 4004;

export function startServer(config, log, { onFirstSubscriber, onLastSubscriber } = {}) {
  const { host, port, tls } = config.server;
  const heartbeatMs = config.server.heartbeatMs ?? 30000;
  const maxRadius = config.limits.maxBoxRadiusKm;
  const authConfig = config.auth || {};
  const auth = makeAuthGate(authConfig, log);
  const authTimeoutMs = (authConfig.authTimeoutSec ?? 10) * 1000;
  const sessionMs = (authConfig.maxSessionHours ?? 4) * 60 * 60 * 1000;

  const http = tls?.enabled
    ? createHttps({ cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) })
    : createHttp();

  const wss = new WebSocketServer({ server: http });
  let subscriberCount = 0;

  wss.on('connection', (socket, req) => {
    const ip = trustedIp(req);

    if (auth.isBanned(ip)) {
      log.debug(`rejecting banned ip ${ip}`);
      socket.close(CLOSE_BANNED, 'banned');
      return;
    }
    // Count existing connections from this IP before tagging the new socket, so
    // an IP gets at most maxConnectionsPerIp open at once.
    if (auth.atConnectionLimit(wss.clients, ip, (c) => c.ip)) {
      log.debug(`rejecting ${ip}: too many connections`);
      socket.close(CLOSE_TOO_MANY, 'too many connections');
      return;
    }

    socket.ip = ip;
    socket.authed = false;
    socket.box = null; // no strikes until the client authenticates and subscribes
    // Heartbeat liveness: the sweep below pings and reaps sockets that stop
    // ponging. A pong (the client's auto-reply) marks the socket alive again.
    socket.isAlive = true;
    socket.on('pong', () => { socket.isAlive = true; });

    // Drop the connection if it doesn't authenticate in time.
    socket.authTimer = setTimeout(() => {
      socket.close(CLOSE_AUTH_TIMEOUT, 'auth timeout');
    }, authTimeoutMs);

    socket.on('message', (data) => {
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return; // ignore malformed messages
      }

      if (!socket.authed) {
        // First message must be { "auth": "<key>" }.
        const friend = auth.validateKey(msg.auth);
        if (friend === null) {
          const banned = auth.recordFailure(ip);
          log.warn(`auth failed from ${ip}${banned ? ' (now banned)' : ''}`);
          socket.close(CLOSE_UNAUTHORIZED, 'unauthorized');
          return;
        }
        clearTimeout(socket.authTimer);
        socket.authTimer = null;
        socket.authed = true;
        socket.friendId = friend;
        // Force re-auth after the session window so key revocations take effect.
        socket.sessionTimer = setTimeout(() => {
          socket.close(CLOSE_SESSION_EXPIRED, 'session expired');
        }, sessionMs);
        socket.send(JSON.stringify({ type: 'ack', ok: true }));
        log.info(`authenticated friend "${friend}" from ${ip}`);
        return;
      }

      if (typeof msg.lat === 'number' && typeof msg.lon === 'number') {
        const wasSubscribed = socket.box !== null;
        const radius = clampRadiusKm(msg.radiusKm, maxRadius);
        socket.box = boxFromCenter(msg.lat, msg.lon, radius);
        if (!wasSubscribed) {
          subscriberCount++;
          if (subscriberCount === 1) onFirstSubscriber?.();
        }
        log.debug(`"${socket.friendId}" subscribed center=${msg.lat},${msg.lon} r=${radius}km (${subscriberCount} active)`);
      }
    });

    socket.on('close', () => {
      clearTimeout(socket.authTimer);
      clearTimeout(socket.sessionTimer);
      if (socket.box) {
        subscriberCount--;
        socket.box = null;
        if (subscriberCount === 0) onLastSubscriber?.();
      }
    });

    socket.on('error', (err) => log.debug(`client error: ${err.message}`));
  });

  http.listen(port, host, () => {
    log.info(`relay listening on ${tls?.enabled ? 'wss' : 'ws'}://${host}:${port}`);
  });

  // Keep client links alive and reap dead ones. The ws-level ping detects sockets
  // that vanished without a clean close (the common case on mobile networks); the
  // app-level { type:'ping' } gives the client a message-stream signal so it can
  // notice a dead relay even behind a proxy that swallows control frames.
  const heartbeat = setInterval(() => {
    for (const socket of wss.clients) {
      if (socket.isAlive === false) {
        socket.terminate();
        continue;
      }
      socket.isAlive = false;
      try {
        socket.ping();
      } catch {
        // socket already going away; the next sweep terminates it
      }
      if (socket.authed && socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify({ type: 'ping' }));
      }
    }
  }, heartbeatMs);
  // Don't keep the process alive just for the heartbeat.
  heartbeat.unref?.();

  // Broadcast a strike to every subscribed client whose box contains it.
  function broadcast(strike) {
    const payload = JSON.stringify({ type: 'strike', ...strike });
    for (const socket of wss.clients) {
      if (socket.readyState === socket.OPEN && socket.box && inBox(strike, socket.box)) {
        socket.send(payload);
      }
    }
  }

  return {
    broadcast,
    close: () => {
      clearInterval(heartbeat);
      auth.stop();
      wss.close();
    },
  };
}
