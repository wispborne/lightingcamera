# Add Relay Authentication

## Problem

The Blitzortung relay is a public WebSocket server with no access control. Deploying it to a VPS means anyone who discovers the endpoint can connect and consume resources. The relay is intended only for friends with the app installed.

## Proposed Solution

Add per-friend key-based authentication to the relay, with IP-level abuse protection. The app sends a key as its first WebSocket message; the relay validates it before accepting subscriptions. Keys are managed per-friend so individual access can be revoked without affecting others.

### Key decisions

- **First-message auth** over the WebSocket (not HTTP headers or URL query params) — works cleanly with any WS library, nothing leaks in logs.
- **Per-friend named keys** in the relay's `config.json` — enables revocation and logging by name.
- **Session expiry** — relay closes connections after a configurable number of hours, forcing transparent reauth on reconnect. This ensures key revocations take effect within that window. Expiry uses its own close code, distinct from auth failure, so the app reconnects on expiry but gives up on a bad key (blind retries would trip the ban threshold).
- **IP banning** — repeated auth failures trigger a temporary IP ban (fail2ban-style).
- **Connection cap** — max 10 connections per IP to prevent resource exhaustion.
- **App-side key entry** — a text field in Settings (prefilled via `--dart-define=RELAY_KEY` at build time). One APK for everyone, keys distributed separately.
- **TLS via Caddy** — relay runs plain `ws://` locally; Caddy handles TLS termination and sets `X-Forwarded-For`.

## Scope

### In scope

- Relay: auth gate, key store, IP ban, connection limit, session expiry, `X-Forwarded-For` trust
- App: relay key setting, auth message on connect, auto-reconnect with backoff, "no key" hint, authenticated "test connection" check (handshake alone no longer proves anything)
- Relay README with key generation instructions

### Rollout

Old app builds send a subscription as their first message, which the relay now counts as an auth failure — deploying the relay change cuts off every un-updated install. Ship the new APK and distribute keys before (or with) the relay deploy.

### Out of scope

- Asymmetric cryptography / challenge-response (overkill for this threat model)
- Per-user rate limiting on strike data
- Admin UI or key management CLI
- Push notifications for connection status
