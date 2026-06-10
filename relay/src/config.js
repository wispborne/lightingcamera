// Loads relay config: starts from config.default.yaml, then overlays an optional
// per-deployment config (gitignored). Nothing operational is hardcoded elsewhere.

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { parse as parseYaml } from 'yaml';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

// Parse a YAML config file. JSON is a subset of YAML, so this also reads a
// plain config.json override unchanged.
function readConfig(path) {
  return parseYaml(readFileSync(path, 'utf8'));
}

// The per-deployment override: RELAY_CONFIG if set, otherwise the first of
// config.yaml / config.yml / config.json found next to the defaults. Null if none.
function resolveOverridePath() {
  const candidates = process.env.RELAY_CONFIG
    ? [process.env.RELAY_CONFIG]
    : ['config.yaml', 'config.yml', 'config.json'].map((name) => join(root, name));
  return candidates.find((path) => existsSync(path)) ?? null;
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
  const defaults = readConfig(join(root, 'config.default.yaml'));
  const overridePath = resolveOverridePath();
  if (overridePath) {
    return merge(defaults, readConfig(overridePath));
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
