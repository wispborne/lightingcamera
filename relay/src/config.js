// Loads relay config: starts from config.default.json, then overlays an optional
// config.json (gitignored, per-deployment). Nothing operational is hardcoded elsewhere.

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

// Shallow-merge with one level of nesting, enough for this config shape.
function merge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over || {})) {
    out[k] = v && typeof v === 'object' && !Array.isArray(v) ? merge(base[k] || {}, v) : v;
  }
  return out;
}

export function loadConfig() {
  const defaults = readJson(join(root, 'config.default.json'));
  const overridePath = process.env.RELAY_CONFIG || join(root, 'config.json');
  if (existsSync(overridePath)) {
    return merge(defaults, readJson(overridePath));
  }
  return defaults;
}

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };

export function makeLogger(level) {
  const threshold = LEVELS[level] ?? LEVELS.info;
  const at = (lvl, fn) => (...args) => {
    if (LEVELS[lvl] <= threshold) fn(`[${lvl}]`, ...args);
  };
  return {
    error: at('error', console.error),
    warn: at('warn', console.warn),
    info: at('info', console.log),
    debug: at('debug', console.log),
  };
}
