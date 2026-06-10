# Design: Relay Authentication

## Relay Side

### Auth gate (`relay/src/auth.js` — new file)

Manages three concerns: key validation, IP ban tracking, and connection counting.

**Key validation:**
- Keys loaded from `config.auth.keys` (object: `{friendName: keyString}`).
- The auth message `{"auth": "<key>"}` carries only the key — there is no name to look up by, so validation iterates every entry and compares the presented key against each stored key.
- Compare with `crypto.timingSafeEqual` to avoid timing side-channels. It throws when buffer lengths differ, so compare SHA-256 digests of both sides (fixed length) instead of the raw strings.
- Return the friend name on match (for logging), or `null` on failure.

**IP ban tracking:**
- In-memory `Map<ip, {failures, firstFailAt, bannedUntil}>`.
- On auth failure: increment failures. If `failures > maxFailures` within `failureWindowSec`, set `bannedUntil` to now + `banDurationMin`.
- On connection from banned IP: close immediately, don't process auth.
- Cleanup timer every 5 minutes: sweep entries whose window and ban have both expired.

**Connection counting:**
- On connection: count existing connections from this IP across `wss.clients`.
- If count >= `maxConnectionsPerIp` (default 10): close immediately.

### Server changes (`relay/src/server.js`)

Updated connection handler flow:

```
wss.on('connection', (socket, req) => {
  const ip = trustedIp(req);          // X-Forwarded-For if from localhost, else raw

  if (isBanned(ip))           → close(4003, 'banned')
  if (connCount(ip) >= max)   → close(4004, 'too many connections')

  socket.authed = false;
  socket.authTimer = setTimeout(      // 10s to send auth, or get dropped
    () => socket.close(4000, 'auth timeout'), 10_000);

  socket.on('message', (data) => {
    if (!socket.authed) {
      // expect {"auth": "<key>"}
      // on success: clearTimeout(socket.authTimer), socket.authed = true,
      //             socket.friendId = name, send {"ok": true}, start session timer
      // on failure: record failure, close(4001, 'unauthorized')
      return;
    }
    // existing subscription logic (lat/lon/radiusKm)
  });

  socket.on('close', ...);            // clear authTimer and session timer
});
```

**Session timer:** After `maxSessionHours`, close the socket with code `4002` (session expired). The app reconnects and re-auths automatically. Session expiry must NOT share a code with auth failure — the app reconnects on one and gives up on the other (see close-code table).

**Trusted IP extraction:** Read `X-Forwarded-For` only when `req.socket.remoteAddress` is loopback — `127.0.0.1`, `::1`, or the IPv4-mapped form `::ffff:127.0.0.1` that Node commonly reports (i.e., from Caddy). Otherwise use the raw socket address. This prevents clients from spoofing the header when connecting directly. The header can be a comma-separated list (a direct client can send its own `X-Forwarded-For`, which Caddy appends to), so take the **last** entry — the one Caddy added. Getting the loopback check wrong is not cosmetic: if it misses, every client behind Caddy shares the raw address `127.0.0.1`, so one friend's auth failures ban everyone and the per-IP connection cap applies to all friends combined.

### Config additions (`config.default.json`)

```json
{
  "auth": {
    "keys": {},
    "maxSessionHours": 4,
    "ban": {
      "maxFailures": 5,
      "failureWindowSec": 60,
      "banDurationMin": 15
    },
    "maxConnectionsPerIp": 10,
    "authTimeoutSec": 10
  }
}
```

Actual keys go in `config.json` (gitignored, per-deployment).

### WebSocket close codes

| Code | Meaning | App reconnects? |
|------|---------|-----------------|
| 4000 | Auth timeout (didn't send auth within 10s) | yes, with backoff |
| 4001 | Unauthorized (bad key) | **no** — retrying a bad key would trip the failure threshold and get the friend's IP banned |
| 4002 | Session expired | yes, immediately (transparent re-auth) |
| 4003 | IP banned | **no** — surface the error |
| 4004 | Too many connections from this IP | yes, with backoff |

## App Side

### Settings (`settings_manager.dart`, `settings_page.dart`)

- New `relayKey` preference in `SettingsManager`, same pattern as `customRelayUrl`.
- Getter: returns saved value if non-empty, else `const String.fromEnvironment('RELAY_KEY')`, else empty. The `const` matters — Flutter only substitutes `--dart-define` values into constant expressions.
- New text field on the settings page, in the Lightning section, below the relay URL field.
- Obscured text (dots), with a visibility toggle.

### Auth in `LightningService`

`connect()` changes:

1. The existing `lightningTestMode` branch stays first — test mode makes no relay connection and must keep working without a key.
2. Then check `settingsManager.relayKey` — if empty, set `_connected.value = false` and return. Don't attempt the connection.
3. After `WebSocketChannel.connect()`, send `{"auth": "<key>"}` as the first message.
4. The `{"ok": true}` ack arrives on the same stream as strikes, so `_onMessage` must recognize it (not log it as a malformed strike): on ack, set `_connected.value = true` and send the subscription.
5. `_connected` is no longer set optimistically right after opening the socket — it now means "authenticated", so the map's connection indicator can't show green for a connection that's about to be rejected.

### Auto-reconnect

On session expiry (`4002`) or unexpected disconnect (`onDone` fires):

- Wait with exponential backoff: 1s, 2s, 4s, 8s, capped at 30s.
- Reconnect and re-auth (transparent to user).
- Reset backoff on successful connection.
- **Never reconnect on `4001` (bad key)** — automatic retries against a wrong or revoked key would hit the failure threshold and get the device's IP banned. Surface the error instead.
- Don't reconnect on `4003` (banned) or if the user manually disconnected.

### Test connection button (`lightning_service.dart`, `settings_page.dart`)

`LightningService.testConnection` currently only awaits the WebSocket handshake. With first-message auth that handshake succeeds for anyone — the relay doesn't reject until the 10s auth timeout — so the button would report success even with a wrong or missing key. Update it to send `{"auth": "<key>"}` after connecting and wait for `{"ok": true}` (5s timeout); a close with `4001` reports "invalid key". The settings page passes the current key along with the URL.

### "No key" hint

When `relayKey` is empty and the user opens the lightning map, show a brief message in place of the connection indicator: "Enter your relay key in Settings to see live strikes." Not shown while `lightningTestMode` is on — test mode needs no key.

## File Changes

| File | Change |
|------|--------|
| `relay/src/auth.js` | New — key validation, IP ban, conn count |
| `relay/src/server.js` | Add auth gate to connection handler |
| `relay/config.default.json` | Add `auth` section with defaults |
| `relay/README.md` | Add key generation instructions |
| `lib/settings/settings_manager.dart` | Add `relayKey` preference |
| `lib/settings/settings_page.dart` | Add relay key text field; pass key to test connection |
| `lib/lightning/lightning_service.dart` | Auth message, auth-aware `_connected`, auto-reconnect, no-key check, authenticated `testConnection` |
| `lib/lightning/lightning_map_page.dart` | "No key" hint |

## Rollout Note

Already-installed app versions send `{lat, lon, radiusKm}` as their first message, which the new gate counts as an auth failure. Deploying the relay change effectively forces everyone onto the updated APK — distribute keys and the new build before (or together with) the relay deploy.
