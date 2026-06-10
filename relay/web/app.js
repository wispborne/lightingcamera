// Lightning world map: live strikes from the relay's /ws feed drawn on a canvas
// overlay, fading over the same 5-minute window and blue->red age ramp as the app
// (lib/lightning/lightning_map_page.dart), with optional thunder wave circles.

'use strict';

// Visual constants mirrored from the app — keep in sync with
// LightningService.displayWindow and lightning_map_page.dart.
const DISPLAY_WINDOW_MS = 5 * 60 * 1000;
const MIN_OPACITY = 0.05;
const SPEED_OF_SOUND_MPS = 343;
const THUNDER_MAX_RADIUS_M = 15 * 1609.344; // 15 miles
const GLOW_AGE_MS = 30 * 1000; // strikes younger than this get a glow halo

const EARTH_CIRCUMFERENCE_M = 40075016.686;
const REGIONAL_ZOOM = 9; // app's opening view when location is known
const WORLD_VIEW = { center: [25, 0], zoom: 2.5 };

// ---------------------------------------------------------------------------
// Map

const map = L.map('map', {
  center: WORLD_VIEW.center,
  zoom: WORLD_VIEW.zoom,
  minZoom: 2,
  zoomSnap: 0.5,
  worldCopyJump: true,
  zoomControl: false,
});

L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
  attribution:
    '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> ' +
    '&copy; <a href="https://carto.com/attributions">CARTO</a> ' +
    '&middot; lightning by <a href="https://www.blitzortung.org/">Blitzortung</a>',
  maxZoom: 19,
}).addTo(map);

// ---------------------------------------------------------------------------
// Strike store

/** @type {{lat: number, lon: number, time: number}[]} sorted by time, pruned each tick */
let strikes = [];

function pruneStrikes() {
  const cutoff = Date.now() - DISPLAY_WINDOW_MS;
  let drop = 0;
  while (drop < strikes.length && strikes[drop].time < cutoff) drop++;
  if (drop > 0) strikes.splice(0, drop);
}

// ---------------------------------------------------------------------------
// Canvas overlay

const canvas = document.createElement('canvas');
canvas.style.cssText =
  'position:absolute;inset:0;z-index:500;pointer-events:none;width:100%;height:100%';
document.getElementById('map').appendChild(canvas);
const ctx = canvas.getContext('2d');

function resizeCanvas() {
  const { x, y } = map.getSize();
  const scale = window.devicePixelRatio || 1;
  canvas.width = Math.round(x * scale);
  canvas.height = Math.round(y * scale);
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
}

function metersPerPixel(lat) {
  return (
    (EARTH_CIRCUMFERENCE_M * Math.abs(Math.cos((lat * Math.PI) / 180))) /
    (256 * Math.pow(2, map.getZoom()))
  );
}

function redraw() {
  const { x: width, y: height } = map.getSize();
  ctx.clearRect(0, 0, width, height);

  const now = Date.now();
  // At low zooms the world repeats horizontally; draw each strike at every
  // visible copy so a zoomed-out view has no blank repeats.
  const worldWidth = map.getPixelWorldBounds().getSize().x;

  for (const strike of strikes) {
    const ageMs = now - strike.time;
    const ageFraction = ageMs / DISPLAY_WINDOW_MS;
    if (ageFraction >= 1) continue;

    // Off-screen skip margin must cover the thunder circle, whose center can sit
    // outside the view while its rim is visible.
    let thunderRadiusPx = 0;
    let thunderRadiusM = 0;
    if (thunderEnabled) {
      const radiusM = SPEED_OF_SOUND_MPS * (ageMs / 1000);
      if (radiusM > 0 && radiusM <= THUNDER_MAX_RADIUS_M) {
        thunderRadiusM = radiusM;
        thunderRadiusPx = radiusM / metersPerPixel(strike.lat);
      }
    }
    const margin = 20 + thunderRadiusPx;

    const point = map.latLngToContainerPoint([strike.lat, strike.lon]);
    if (point.y < -margin || point.y > height + margin) continue;

    // Same ramp as the app: hue 240 (new, blue) -> 0 (old, red), opacity
    // 1 -> 0.05.
    const alpha = Math.max(1 - ageFraction, MIN_OPACITY);
    const hue = 240 * (1 - ageFraction);

    // Normalize to the leftmost copy that could touch the view, then step right.
    const firstX = ((point.x % worldWidth) + worldWidth) % worldWidth - worldWidth;
    for (let x = firstX; x < width + margin; x += worldWidth) {
      if (x < -margin) continue;

      if (ageMs < GLOW_AGE_MS) {
        ctx.fillStyle = `hsla(${hue}, 100%, 60%, ${alpha * 0.35})`;
        ctx.beginPath();
        ctx.arc(x, point.y, 8, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.fillStyle = `hsla(${hue}, 100%, 55%, ${alpha * 0.9})`;
      ctx.beginPath();
      ctx.arc(x, point.y, 3.5, 0, Math.PI * 2);
      ctx.fill();

      if (thunderRadiusPx > 1) {
        const fade = Math.max(0, 1 - thunderRadiusM / THUNDER_MAX_RADIUS_M);
        ctx.strokeStyle = `rgba(79, 195, 247, ${fade})`;
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(x, point.y, thunderRadiusPx, 0, Math.PI * 2);
        ctx.stroke();
      }
    }
  }
}

map.on('move zoom', redraw);
map.on('resize', () => {
  resizeCanvas();
  redraw();
});
resizeCanvas();

// ---------------------------------------------------------------------------
// Redraw cadence: 1 Hz is enough for the age fade; the thunder front moves at
// 343 m/s, so circles get ~15 fps to sweep smoothly.

let ticker = null;

function startTicker() {
  clearInterval(ticker);
  ticker = setInterval(() => {
    pruneStrikes();
    updateStatus();
    redraw();
  }, thunderEnabled ? 66 : 1000);
}

// ---------------------------------------------------------------------------
// Thunder toggle

const thunderButton = document.getElementById('thunder-toggle');
let thunderEnabled = localStorage.getItem('thunderCircles') === '1';

function applyThunderState() {
  thunderButton.classList.toggle('active', thunderEnabled);
  startTicker();
  redraw();
}

thunderButton.addEventListener('click', () => {
  thunderEnabled = !thunderEnabled;
  localStorage.setItem('thunderCircles', thunderEnabled ? '1' : '0');
  applyThunderState();
});
applyThunderState();

// ---------------------------------------------------------------------------
// Tick sound: a short Geiger-style click for every live strike that lands inside
// the current view. Synthesized with WebAudio so there's no asset to load.

const soundButton = document.getElementById('sound-toggle');
let soundEnabled = localStorage.getItem('tickSound') === '1';
let audioCtx = null;
let lastTickAt = 0;

// Browsers keep an AudioContext suspended until a user gesture. The toggle click
// is a gesture; for a page that loads with sound already enabled, the first
// click/tap anywhere unlocks it.
function ensureAudio() {
  if (!audioCtx) audioCtx = new AudioContext();
  if (audioCtx.state === 'suspended') audioCtx.resume();
}

document.addEventListener('pointerdown', () => {
  if (soundEnabled) ensureAudio();
}, { once: true });

function tick() {
  const t = audioCtx.currentTime;
  const osc = audioCtx.createOscillator();
  const gain = audioCtx.createGain();
  osc.type = 'square';
  osc.frequency.value = 1800;
  gain.gain.setValueAtTime(0.12, t);
  gain.gain.exponentialRampToValueAtTime(0.001, t + 0.03);
  osc.connect(gain).connect(audioCtx.destination);
  osc.start(t);
  osc.stop(t + 0.04);
}

function strikeOnScreen(strike) {
  const { x: width, y: height } = map.getSize();
  const point = map.latLngToContainerPoint([strike.lat, strike.lon]);
  if (point.y < 0 || point.y > height) return false;
  // Check every horizontal world copy, same wrap handling as redraw().
  const worldWidth = map.getPixelWorldBounds().getSize().x;
  const xNorm = ((point.x % worldWidth) + worldWidth) % worldWidth;
  return xNorm <= width || xNorm >= worldWidth - 5;
}

function maybeTick(strike) {
  if (!soundEnabled || !audioCtx || audioCtx.state !== 'running') return;
  // A worldwide storm peak is tens of strikes per second; saturate like a Geiger
  // counter instead of stacking clicks into noise.
  const now = performance.now();
  if (now - lastTickAt < 25) return;
  if (!strikeOnScreen(strike)) return;
  lastTickAt = now;
  tick();
}

function applySoundState() {
  soundButton.classList.toggle('active', soundEnabled);
}

soundButton.addEventListener('click', () => {
  soundEnabled = !soundEnabled;
  localStorage.setItem('tickSound', soundEnabled ? '1' : '0');
  if (soundEnabled) ensureAudio();
  applySoundState();
});
applySoundState();

// ---------------------------------------------------------------------------
// Status pill

const statusDot = document.getElementById('status-dot');
const statusText = document.getElementById('status-text');
const strikeCount = document.getElementById('strike-count');
let connected = false;

function updateStatus() {
  statusDot.classList.toggle('connected', connected);
  statusText.textContent = connected ? 'live' : 'reconnecting';
  strikeCount.textContent = `⚡ ${strikes.length}`;
}

// ---------------------------------------------------------------------------
// Relay websocket: backlog seeds the store, live strikes append, pings are
// keepalives. Reconnect with exponential backoff, reset on a good connection.

const WS_URL = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;
let backoffMs = 1000;

function connect() {
  const socket = new WebSocket(WS_URL);

  socket.onopen = () => {
    connected = true;
    backoffMs = 1000;
    updateStatus();
  };

  socket.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }
    if (msg.type === 'backlog' && Array.isArray(msg.strikes)) {
      strikes = msg.strikes;
      pruneStrikes();
      redraw();
    } else if (msg.type === 'strike') {
      strikes.push({ lat: msg.lat, lon: msg.lon, time: msg.time });
      maybeTick(msg);
    }
    // 'ping' and unknown types: keepalive only, nothing to do.
  };

  socket.onclose = () => {
    connected = false;
    updateStatus();
    setTimeout(connect, backoffMs);
    backoffMs = Math.min(backoffMs * 2, 30000);
  };

  socket.onerror = () => socket.close();
}

connect();

// ---------------------------------------------------------------------------
// Visitor location: center on success, stay at the world view otherwise.

const note = document.getElementById('note');

// A my_location-style crosshair (ring + center dot + ticks), like the app's marker.
// Deliberately not a filled glowing dot — that's what strikes look like.
const youAreHereIcon = L.divIcon({
  className: 'you-are-here',
  iconSize: [24, 24],
  html:
    '<svg viewBox="0 0 24 24" width="24" height="24">' +
    '<g stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round">' +
    '<circle cx="12" cy="12" r="6.5"/>' +
    '<path d="M12 1.5v3M12 19.5v3M1.5 12h3M19.5 12h3"/>' +
    '</g>' +
    '<circle cx="12" cy="12" r="2" fill="#fff"/>' +
    '</svg>',
});

if (navigator.geolocation) {
  navigator.geolocation.getCurrentPosition(
    (pos) => {
      const here = [pos.coords.latitude, pos.coords.longitude];
      map.setView(here, REGIONAL_ZOOM);
      L.marker(here, { icon: youAreHereIcon, interactive: false }).addTo(map);
    },
    () => {
      note.textContent = 'Location unavailable — showing world view';
    },
    { enableHighAccuracy: false, timeout: 10000 },
  );
} else {
  note.textContent = 'Location unavailable — showing world view';
}
