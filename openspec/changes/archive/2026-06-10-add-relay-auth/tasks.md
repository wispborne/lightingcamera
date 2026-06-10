# Tasks: Relay Authentication

## Relay

- [x] Add `auth` section to `config.default.json` with defaults (empty keys, session hours, ban thresholds, connection limit)
- [x] Create `relay/src/auth.js` — key validation that iterates all entries comparing SHA-256 digests via `timingSafeEqual` (raw strings would throw on length mismatch), IP ban tracker (failures/bans map, cleanup timer), connection counter, trusted IP extraction (`X-Forwarded-For` only from loopback incl. `::ffff:127.0.0.1`, take the **last** list entry)
- [x] Update `relay/src/server.js` — auth gate in connection handler: IP ban check, connection limit check, auth timeout, first-message key validation, session expiry timer, custom close codes (4000–4004; 4001 = bad key, 4002 = session expired — distinct so the app knows when to reconnect), clear auth/session timers on auth success and socket close
- [x] Add key generation instructions to `relay/README.md`

## App — Settings

- [x] Add `relayKey` to `SettingsManager` — saved preference with `const String.fromEnvironment('RELAY_KEY')` fallback (`const` is required for `--dart-define` to be substituted)
- [x] Add relay key text field to settings page — obscured input with visibility toggle, in the Lightning section below relay URL

## App — Auth & Reconnect

- [x] Update `LightningService.connect()` — keep the test-mode branch first (test mode needs no key), then skip connection if no key, send `{"auth": key}` as first message, handle the `{"ok": true}` ack in `_onMessage` (set `_connected` true and subscribe only then — no longer optimistically on socket open)
- [x] Update `LightningService.testConnection` to authenticate — send the auth message and await `{"ok": true}`; the handshake alone now succeeds for anyone, so the old check would report false success. Settings page passes the current key.
- [x] Add auto-reconnect with exponential backoff (1s→30s cap) on unexpected disconnect or session expiry (4002); never reconnect on bad key (4001 — retries would get the IP banned) or ban (4003)
- [x] Add "no key" hint to lightning map page when `relayKey` is empty (hidden in test mode)
