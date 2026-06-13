# Lightning Relay

A small Node service for **Lightning Camera**. It holds one upstream websocket to the
[Blitzortung](https://www.blitzortung.org/) community lightning network, decodes the feed,
and fans strikes out to app clients — filtered to a bounding box around each user.

A relay exists because Blitzortung's data policy requires third-party apps to serve data
from their own server rather than connecting every phone directly. It also keeps the
decode/reconnect logic in one place.

> **Non-commercial only.** Blitzortung data may not be used commercially. Keep any app
> built on this free and publicly accessible.

## Layout

```
relay/
├── index.js              # entry point: wires upstream -> servers
├── spike.js              # standalone go/no-go test (prints decoded strikes)
├── config.default.yaml  # shipped, commented defaults (do not edit; overlay with config.yaml)
├── lightning-relay.service  # systemd unit for the VPS
├── src/
│   ├── decode.js         # Blitzortung LZW decode + strike normalization
│   ├── config.js         # config loader (defaults <- config.yaml) + logger
│   ├── geo.js            # center+radius -> bounding box, in-box test
│   ├── upstream.js       # Blitzortung connection, reconnect/failover, heartbeat
│   ├── subscribers.js    # shared gauge: live count of app + web viewers
│   ├── server.js         # app-facing websocket server + box fan-out
│   └── web.js            # browser-facing world map: static page + unfiltered /ws
└── web/                  # the world map page (vanilla JS + vendored Leaflet)
```

## Run locally

```bash
npm install
npm run spike     # sanity check: prints 5 decoded strikes, then exits
npm start         # start the relay on ws://0.0.0.0:8787
```

## Client protocol

1. App connects to the relay websocket.
2. App authenticates with its key as the **first** message: `{ "auth": "<key>" }`.
   The relay replies `{ "type": "ack", "ok": true }` on success, or closes the socket
   with code `4001` on a bad key. A client that doesn't authenticate within
   `auth.authTimeoutSec` is dropped (code `4000`).
3. App sends a subscription: `{ "lat": 40.1, "lon": -95.2, "radiusKm": 150 }`.
   (`radiusKm` is clamped to `limits.maxBoxRadiusKm`.) The app may re-send this at any
   time to move its box — e.g. as the user's GPS location changes.
4. Relay streams matching strikes: `{ "type": "strike", "lat": <deg>, "lon": <deg>, "time": <ms epoch> }`.

Every message the relay sends is tagged with a `type`, so the app can switch on it and
ignore message types it doesn't know — letting the protocol grow without breaking older
builds. The `ok` field on the ack is kept for backward compatibility.

### Keepalive

The relay pings each socket every `server.heartbeatMs` (default 30s): a ws-level ping
reaps half-open connections server-side, and an app-level `{ "type": "ping" }` lets the
client tell a live-but-silent link (no strikes for a while) from a dead one. The app
treats the link as dead and reconnects if nothing — strike or ping — arrives within its
own stale window (~2.5× the heartbeat).

### Close codes

| Code | Meaning | App reconnects? |
|------|---------|-----------------|
| 4000 | Auth timeout (no auth within `authTimeoutSec`) | yes, with backoff |
| 4001 | Unauthorized (bad/revoked key) | no — surfaces an error |
| 4002 | Session expired (after `maxSessionHours`) | yes, immediately (re-auths) |
| 4003 | IP banned (too many auth failures) | no |
| 4004 | Too many connections from this IP | yes, with backoff |

## Authentication

The relay is private — only friends with a key may connect. Keys live in `config.yaml`
under `auth.keys`, mapping a friend's name to their key:

```yaml
auth:
  keys:
    alice: Kx7f2pQ9...
    bob: 9mWv3sLc...
```

Generate a key (a long random string — 32 bytes base64 is plenty):

```bash
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
```

Add the friend's name and key to `auth.keys`, restart the relay, and send them the key
to enter in the app's Settings (or bake it into their build with
`--dart-define=RELAY_KEY=<key>`). To revoke access, delete that friend's entry and
restart — their next reconnect (within `maxSessionHours`) is rejected.

Other `auth` settings (see `config.default.yaml`): `maxSessionHours` forces periodic
re-auth, `maxConnectionsPerIp` caps simultaneous connections, and `ban` controls how
many auth failures within `failureWindowSec` trigger a `banDurationMin` IP ban.

> **Behind a reverse proxy:** the relay trusts `X-Forwarded-For` only from loopback,
> so bans and connection limits track real client IPs. Make sure Caddy/nginx sets that
> header and proxies from `127.0.0.1`.

## Configuration

Edit a `config.yaml` next to `config.default.yaml` (gitignored). Any keys you set overlay
the defaults; omit the rest. `config.default.yaml` is commented and documents the full
shape — upstream URLs, `server.host`/`port`/`tls`/`heartbeatMs`, `limits.maxBoxRadiusKm`,
`maxStrikeAgeMs`, reconnect timings, and `log.level`. A `config.json` override still works
too, since JSON is valid YAML.

You can also point at a config elsewhere with `RELAY_CONFIG=/path/to/config.yaml`.

## Deploy to the VPS

```bash
# on the VPS
git clone <repo> /opt/lightning-relay && cd /opt/lightning-relay/relay
npm install --omit=dev
sudo useradd --system --no-create-home lightning   # or reuse an existing user

# install the service (edit WorkingDirectory/User/paths first)
sudo cp lightning-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lightning-relay
journalctl -u lightning-relay -f
```

### TLS

The app needs `wss://`. Two options:

- **Reverse proxy (recommended):** terminate TLS at nginx/Caddy and proxy the websocket to
  `127.0.0.1:8787`. Leave `server.tls.enabled` = `false`.
- **Direct:** set `server.tls.enabled` = `true` and point `certPath`/`keyPath` at your
  certificate.

Then set the app's relay URL (see `lib/lightning/lightning_service.dart`) to your
`wss://your-host/...` endpoint.

## World map page

An optional browser map (like lightningmaps.org): a full-screen dark world map showing
**every** strike worldwide, fading over the same 5-minute window as the app, with the
visitor's GPS position and an optional thunder-wave circle per strike (343 m/s, capped
at 15 miles — the app's constants). Served by the relay itself on a second port so the
reverse proxy can gate it separately from the app websocket.

Enable it in `config.yaml`:

```yaml
web:
  enabled: true
```

Defaults (see `config.default.yaml`): binds `127.0.0.1:8788`, replays a backlog of the
last 5 minutes of strikes to a newly opened page (capped at `backlogMaxStrikes`).

### Protocol

The page's websocket (`/ws`) needs **no key** — the relay sends without being asked:

- `{ "type": "backlog", "strikes": [...] }` once on connect (last 5 minutes, worldwide)
- `{ "type": "strike", "lat", "lon", "time" }` live
- `{ "type": "ping" }` keepalives

Viewers count as subscribers for the live-count gauge, but the upstream Blitzortung
connection is always open — the page starts receiving strikes immediately.

### Auth: Caddy + tinyauth

Because the web port has no key auth, **never expose it directly** — keep
`web.host` on `127.0.0.1` and put Caddy with [tinyauth](https://tinyauth.app/)
`forward_auth` in front:

```caddyfile
map.example.com {
    forward_auth localhost:3000 {       # tinyauth
        uri /api/auth/caddy
        copy_headers Remote-User
    }
    reverse_proxy 127.0.0.1:8788        # websocket upgrade is proxied automatically
}
```

tinyauth runs and is configured separately (its docs cover users and OAuth). The
app-facing relay domain stays as-is — app keys, no tinyauth. Note that browsers only
allow geolocation on HTTPS pages, which Caddy's automatic TLS provides; on plain HTTP
the page quietly falls back to the world view.

### Frontend notes

`web/` is plain HTML/JS/CSS with no build step. Leaflet is vendored under
`web/vendor/leaflet/` (copied from the `leaflet` npm devDependency) so the page loads
without a CDN; map tiles come from CARTO's dark basemap (free for non-commercial use).
Strikes draw on a single canvas overlay, so tens of thousands of worldwide strikes
render without breaking a sweat. The thunder toggle persists in `localStorage`.
