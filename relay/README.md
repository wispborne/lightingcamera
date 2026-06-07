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
├── index.js              # entry point: wires upstream -> server
├── spike.js              # standalone go/no-go test (prints decoded strikes)
├── config.default.json   # shipped defaults (do not edit; overlay with config.json)
├── lightning-relay.service  # systemd unit for the VPS
└── src/
    ├── decode.js         # Blitzortung LZW decode + strike normalization
    ├── config.js         # config loader (defaults <- config.json) + logger
    ├── geo.js            # center+radius -> bounding box, in-box test
    ├── upstream.js       # Blitzortung connection, reconnect/failover, heartbeat
    └── server.js         # client-facing websocket server + box fan-out
```

## Run locally

```bash
npm install
npm run spike     # sanity check: prints 5 decoded strikes, then exits
npm start         # start the relay on ws://0.0.0.0:8787
```

## Client protocol

1. App connects to the relay websocket.
2. App sends a subscription: `{ "lat": 40.1, "lon": -95.2, "radiusKm": 150 }`.
   (`radiusKm` is clamped to `limits.maxBoxRadiusKm`.)
3. Relay streams matching strikes: `{ "lat": <deg>, "lon": <deg>, "time": <ms epoch> }`.

## Configuration

Edit a `config.json` next to `config.default.json` (gitignored). Any keys you set overlay
the defaults; omit the rest. See `config.default.json` for the full shape — upstream URLs,
`server.host`/`port`/`tls`, `limits.maxBoxRadiusKm`, `maxStrikeAgeMs`, reconnect timings,
and `log.level`.

You can also point at a config elsewhere with `RELAY_CONFIG=/path/to/config.json`.

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
