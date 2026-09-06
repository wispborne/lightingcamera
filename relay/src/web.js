// Browser-facing world map server: serves the static page from web/ and streams
// every decoded strike worldwide over /ws — no bounding box, no relay key. Auth is
// the reverse proxy's job (Caddy + tinyauth); the default bind is localhost so the
// port is unreachable except through the proxy.

import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { dirname, join, normalize, resolve, sep } from 'node:path';
import { WebSocketServer } from 'ws';

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, '..', 'web');

// Disconnect a viewer once this much outbound data is sitting unread in its
// socket buffer — it isn't keeping up and the backlog only grows.
const MAX_BUFFERED_BYTES = 1024 * 1024;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

// Tile settings the page reads before building the map. Served as a script
// rather than baked into app.js so a deployment's own tile server stays in
// config.yaml, which is gitignored — the checked-in default is OpenStreetMap, so
// a fresh clone works with no configuration.
function serveConfig(config, res) {
  const tiles = config.web?.tiles ?? {};
  const body = `window.MAP_CONFIG = ${JSON.stringify({ tiles })};
`;
  res.writeHead(200, {
    'Content-Type': MIME['.js'],
    'Cache-Control': 'no-cache',
  });
  res.end(body);
}

function serveStatic(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405).end();
    return;
  }
  const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const relative = urlPath === '/' ? 'index.html' : urlPath.slice(1);
  const path = resolve(webRoot, normalize(relative));

  // Whitelisted extensions only, and never outside web/ — belt and suspenders
  // against traversal even though resolve+normalize already collapses "..".
  const ext = path.slice(path.lastIndexOf('.'));
  const mime = MIME[ext];
  if (!mime || !path.startsWith(webRoot + sep) || !existsSync(path) || !statSync(path).isFile()) {
    res.writeHead(404).end('not found');
    return;
  }
  res.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-cache' });
  if (req.method === 'HEAD') {
    res.end();
    return;
  }
  createReadStream(path).pipe(res);
}

export function startWeb(config, log, subscribers, history) {
  const { host, port } = config.web;
  const heartbeatMs = config.web.heartbeatMs ?? 30000;

  const http = createServer((req, res) => {
    // Generated, so it never matches a file in web/ and must be handled first.
    if (new URL(req.url, 'http://x').pathname === '/config.js') {
      serveConfig(config, res);
      return;
    }
    serveStatic(req, res);
  });
  const wss = new WebSocketServer({ server: http, path: '/ws' });

  wss.on('connection', (socket) => {
    socket.isAlive = true;
    socket.on('pong', () => { socket.isAlive = true; });
    socket.on('error', (err) => log.debug(`web client error: ${err.message}`));
    socket.on('close', () => subscribers.remove());
    // Viewers count as subscribers so the lazy upstream connects for them too.
    subscribers.add();

    // Seed the page from the shared history — the worldwide query, since the
    // web map has no bounding box.
    socket.send(JSON.stringify({ type: 'backlog', strikes: history.query() }));
    log.debug(`web viewer connected (${subscribers.count} active)`);
    // Inbound messages are ignored: the web protocol is server -> client only.
  });

  http.listen(port, host, () => {
    log.info(`web map listening on http://${host}:${port}`);
  });

  // Same liveness sweep as the app server: ws-level ping reaps half-open sockets,
  // app-level {type:'ping'} lets the page tell a quiet link from a dead one.
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
      if (socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify({ type: 'ping' }));
      }
    }
  }, heartbeatMs);
  heartbeat.unref?.();

  function broadcast(strike) {
    const payload = JSON.stringify({ type: 'strike', ...strike });
    for (const socket of wss.clients) {
      if (socket.readyState !== socket.OPEN) continue;
      // A viewer that reads slower than the feed (throttled tab, bad link) would
      // otherwise make us buffer the worldwide feed for it without limit. Drop
      // it instead — the page reconnects and re-seeds from history.
      if (socket.bufferedAmount > MAX_BUFFERED_BYTES) {
        log.debug('web viewer too far behind; dropping it');
        socket.terminate();
        continue;
      }
      socket.send(payload);
    }
  }

  return {
    broadcast,
    close: () => {
      clearInterval(heartbeat);
      wss.close();
      http.close();
    },
  };
}
