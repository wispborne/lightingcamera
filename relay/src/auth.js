// Access control for the client-facing server: per-friend key validation, IP ban
// tracking (fail2ban-style), and a per-IP connection cap. All state is in-memory —
// bans reset on restart, which is fine for this threat model.

import { createHash, timingSafeEqual } from 'node:crypto';

/** SHA-256 digest of a string, as a Buffer. Fixed length so timingSafeEqual is safe. */
function digest(value) {
  return createHash('sha256').update(value, 'utf8').digest();
}

/**
 * Build an auth gate from the `config.auth` section.
 *
 * Returns helpers the server wires into its connection handler. `wss.clients` is
 * passed in for connection counting so the gate doesn't own the server.
 */
export function makeAuthGate(authConfig, log) {
  const keys = authConfig.keys || {};
  const ban = authConfig.ban || {};
  const maxFailures = ban.maxFailures ?? 5;
  const failureWindowMs = (ban.failureWindowSec ?? 60) * 1000;
  const banDurationMs = (ban.banDurationMin ?? 15) * 60 * 1000;
  const maxConnectionsPerIp = authConfig.maxConnectionsPerIp ?? 10;

  // Precompute the digest for each stored key so validation doesn't rehash them
  // on every attempt.
  const entries = Object.entries(keys).map(([name, key]) => ({
    name,
    keyDigest: digest(key),
  }));

  // ip -> { failures, firstFailAt, bannedUntil }
  const offenders = new Map();

  /**
   * Validate a presented key against every stored key. There's no name in the
   * auth message to look up by, so we compare against each. Digests are compared
   * with timingSafeEqual (constant time, and fixed length so it won't throw on a
   * length mismatch the way raw key strings would).
   *
   * Returns the friend name on match, or null on failure.
   */
  function validateKey(presented) {
    if (typeof presented !== 'string' || presented.length === 0) return null;
    const presentedDigest = digest(presented);
    let matched = null;
    // Iterate every entry (don't early-return) so total work doesn't reveal how
    // close a guess was.
    for (const entry of entries) {
      if (timingSafeEqual(presentedDigest, entry.keyDigest)) {
        matched = entry.name;
      }
    }
    return matched;
  }

  /** True if this IP is currently banned. */
  function isBanned(ip) {
    const record = offenders.get(ip);
    if (!record || !record.bannedUntil) return false;
    return record.bannedUntil > now();
  }

  /**
   * Record an auth failure for this IP. If failures exceed the threshold within
   * the window, ban the IP. Returns true if the IP is now banned.
   */
  function recordFailure(ip) {
    const t = now();
    let record = offenders.get(ip);
    if (!record || t - record.firstFailAt > failureWindowMs) {
      record = { failures: 0, firstFailAt: t, bannedUntil: 0 };
      offenders.set(ip, record);
    }
    record.failures++;
    if (record.failures > maxFailures) {
      record.bannedUntil = t + banDurationMs;
      log.warn(`banning ${ip} for ${banDurationMs / 60000}min (${record.failures} auth failures)`);
      return true;
    }
    return false;
  }

  /** Count current connections from this IP across the server's clients. */
  function connectionCount(clients, ip, ipOf) {
    let count = 0;
    for (const client of clients) {
      if (ipOf(client) === ip) count++;
    }
    return count;
  }

  /** True if this IP already has the maximum allowed connections. */
  function atConnectionLimit(clients, ip, ipOf) {
    return connectionCount(clients, ip, ipOf) >= maxConnectionsPerIp;
  }

  // Sweep stale offender records every 5 minutes: drop entries whose failure
  // window and ban have both expired.
  const cleanupTimer = setInterval(() => {
    const t = now();
    for (const [ip, record] of offenders) {
      const windowExpired = t - record.firstFailAt > failureWindowMs;
      const banExpired = !record.bannedUntil || record.bannedUntil <= t;
      if (windowExpired && banExpired) offenders.delete(ip);
    }
  }, 5 * 60 * 1000);
  // Don't keep the process alive just for the sweep.
  cleanupTimer.unref?.();

  return {
    validateKey,
    isBanned,
    recordFailure,
    atConnectionLimit,
    stop: () => clearInterval(cleanupTimer),
  };
}

function now() {
  return Date.now();
}

/**
 * The client IP to attribute this connection to. Trust `X-Forwarded-For` only when
 * the immediate peer is loopback (i.e. our own reverse proxy, Caddy) — otherwise a
 * direct client could spoof it. The header may be a comma-separated list (a direct
 * client can send its own, which Caddy appends to), so take the LAST entry, which
 * is the one Caddy added.
 */
export function trustedIp(req) {
  const remote = req.socket.remoteAddress || '';
  if (isLoopback(remote)) {
    const forwarded = req.headers['x-forwarded-for'];
    if (forwarded) {
      const parts = forwarded.split(',');
      const last = parts[parts.length - 1].trim();
      if (last) return last;
    }
  }
  return remote;
}

/** Loopback in any form Node may report, including the IPv4-mapped IPv6 address. */
function isLoopback(addr) {
  return addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1';
}
