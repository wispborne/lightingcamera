// Go/no-go spike: connect to Blitzortung, send the init message, and print
// decoded {lat, lon, time} for the first few strikes. If this prints real-looking
// coordinates, the whole change is viable. Run with:  node spike.js
//
// Exits on its own after N strikes or a timeout so it can be run in CI/by hand.

import WebSocket from 'ws';
import { parseStrikeMessage, normalizeStrike } from './src/decode.js';

const URL = process.env.BO_URL || 'wss://ws1.blitzortung.org/';
const INIT = JSON.stringify({ a: 111 });
const MAX_STRIKES = Number(process.env.BO_MAX || 5);
const TIMEOUT_MS = Number(process.env.BO_TIMEOUT || 30000);

console.log(`[spike] connecting to ${URL} ...`);
const ws = new WebSocket(URL);

let seen = 0;
const timer = setTimeout(() => {
  console.error(`[spike] TIMEOUT after ${TIMEOUT_MS}ms with ${seen} strike(s). No data?`);
  ws.close();
  process.exit(seen > 0 ? 0 : 2);
}, TIMEOUT_MS);

ws.on('open', () => {
  console.log(`[spike] connected. sending init ${INIT}`);
  ws.send(INIT);
});

ws.on('message', (data) => {
  const raw = data.toString();
  const parsed = parseStrikeMessage(raw);
  if (!parsed) {
    console.warn('[spike] could not parse message (first 80 chars):', raw.slice(0, 80));
    return;
  }
  const strike = normalizeStrike(parsed);
  if (!strike) {
    // Some messages are not strikes (keepalives / metadata). Show keys to learn the shape.
    console.log('[spike] non-strike message, keys:', Object.keys(parsed));
    return;
  }
  seen++;
  const when = new Date(strike.time).toISOString();
  console.log(
    `[spike] strike #${seen}: lat=${strike.lat.toFixed(4)} lon=${strike.lon.toFixed(4)} time=${when}`
  );
  if (seen >= MAX_STRIKES) {
    console.log(`[spike] GO — decoded ${seen} strikes successfully.`);
    clearTimeout(timer);
    ws.close();
    process.exit(0);
  }
});

ws.on('error', (err) => {
  console.error('[spike] websocket error:', err.message);
  clearTimeout(timer);
  process.exit(1);
});

ws.on('close', () => {
  console.log('[spike] connection closed.');
});
