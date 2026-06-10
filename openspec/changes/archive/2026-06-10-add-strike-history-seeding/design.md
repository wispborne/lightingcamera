# Design: Strike History Seeding

## Overview

The relay already buffers 5 minutes of strikes — but privately, inside `web.js`,
where only browser viewers can see it. This change lifts that buffer into a shared
module that both fronts query:

```
 Blitzortung ──▶ index.js ──▶ history.add(strike) ──┬─▶ server.broadcast  (live, box-filtered)
                                                    └─▶ web.broadcast     (live, worldwide)
                                  ▲           ▲
        server.js: on subscribe ──┘           └── web.js: on connect
        history.query(box) → backlog       history.query() → backlog
```

## Key Decisions

1. **One shared module (`relay/src/history.js`), not two buffers.** The web
   backlog and the new app backlog are the same data with different filters;
   keeping two copies would double memory during worldwide peaks and let the two
   fronts drift apart.
2. **Backlog rides the existing websocket protocols** — no HTTP endpoint. The app
   already has an authenticated socket and a subscription box; replying with a
   `backlog` message on subscribe reuses auth, box clamping, and the
   `type`-tagged protocol that lets old clients skip unknown messages.
3. **Backlog on every subscription, store-replace on the client.** A
   re-subscription (user moved ≥ 10 km, or reconnect after a drop) gets a fresh
   backlog for the new box, and the app replaces its strike list with it. Replace
   (the web page's existing strategy) makes duplicates impossible without strike
   IDs — the backlog is the authoritative last-5-minutes for the current box, so
   nothing worth keeping is lost.
4. **Config moves to a shared `history` section.** `web.backlogMaxStrikes` made
   sense when the buffer was web-only; the cap now guards one shared buffer. The
   old key is read as a fallback so existing deployment overrides keep working.
5. **The lazy upstream stays lazy.** History fills only while someone holds the
   upstream open; the first subscriber after idle gets an empty backlog. Keeping
   the upstream connected just to warm the history would mean permanently
   consuming the Blitzortung feed — explicitly out of scope.
6. **Persistence is a whole-buffer snapshot, not an append log.** The buffer
   tops out around 20k strikes (~1 MB of JSON), and only the last 5 minutes ever
   matter, so rewriting one file every few seconds is cheaper and simpler than
   an append-only log with rotation. Writes go to a temp file then `rename` —
   atomic on the same filesystem — so a crash mid-write leaves the previous
   snapshot intact, never a torn one.

## Relay Changes

### `relay/src/history.js` (new)

```js
export function makeStrikeHistory({ windowMs, maxStrikes, snapshotPath, snapshotIntervalMs, log }) {
  const strikes = [];  // append-only in arrival order; pruned from the front
  function prune() { /* drop strikes older than windowMs, then enforce maxStrikes */ }
  return {
    add(strike) { strikes.push(strike); prune(); /* mark dirty */ },
    query(box = null) {
      prune();
      return box ? strikes.filter((s) => inBox(s, box)) : [...strikes];
    },
    save() { /* prune, write snapshot atomically (sync; used on shutdown) */ },
    stop() { /* clear the snapshot timer, save once more */ },
  };
}
```

Strikes arrive in near-chronological order from one upstream, so front-pruning an
array is sufficient (same approach `web.js` uses today). `windowMs` is the
5-minute display window, declared here as the single source of truth and exported
for `web.js`.

**Snapshot behaviour, all internal to this module:**

- **Load:** on construction, read `snapshotPath` if present, validate it's an
  array of `{lat, lon, time}` objects, prune to the window, and seed `strikes`.
  Any read/parse failure logs a warning and starts empty (spec R6.4).
- **Save:** a `setInterval` (unref'd, default 10 s) writes the pruned buffer as
  JSON — but only when strikes were added since the last save, so an idle relay
  doesn't grind the disk. Each save writes `<path>.tmp` then renames over the
  real file.
- **Shutdown:** `index.js` calls `history.stop()` in its shutdown handler, which
  saves synchronously (`writeFileSync` + `renameSync`) — safe to do in a signal
  handler and guarantees the final state lands before `process.exit`.

### `relay/src/server.js`

`startServer(config, log, subscribers, history)`. In the subscription handler,
after `socket.box` is set:

```js
socket.send(JSON.stringify({ type: 'backlog', strikes: history.query(socket.box) }));
```

Sent on every subscription message (first and re-subscribe), per spec R3.2.

### `relay/src/web.js`

`startWeb(config, log, subscribers, history)`. Delete the private `backlog` array,
`pruneBacklog()`, and the `DISPLAY_WINDOW_MS` constant (now imported from
`history.js`). On connection, send `history.query()` instead. `broadcast` no
longer pushes into a local buffer.

### `relay/index.js`

```js
const history = makeStrikeHistory({
  windowMs: DISPLAY_WINDOW_MS,
  maxStrikes: config.history?.maxStrikes ?? config.web?.backlogMaxStrikes ?? 20000,
  snapshotPath: config.history?.snapshotPath ?? 'strike-history.json',
  snapshotIntervalMs: config.history?.snapshotIntervalMs ?? 10000,
  log,
});
```

The upstream strike callback adds to history before broadcasting, so a strike
that arrives between a subscribe and its backlog reply can't be lost — it's
either in the backlog or broadcast after it. The relative default path resolves
against the relay directory (same convention as the config file), and `shutdown`
calls `history.stop()` before `process.exit` so the final snapshot lands.

### `relay/config.default.yaml`

```yaml
# Rolling history of recent strikes, replayed to clients on connect so their maps
# start populated. Covers the 5-minute display window, capped by count, and
# snapshotted to disk so a quick relay restart doesn't blank everyone's map.
history:
  maxStrikes: 20000
  # Snapshot file, relative to the relay directory. Set to "" to disable
  # persistence (history then lives only in memory).
  snapshotPath: strike-history.json
  # How often (ms) to rewrite the snapshot while strikes are arriving.
  snapshotIntervalMs: 10000
```

Remove `web.backlogMaxStrikes` from the defaults (kept as a read-fallback in
code). Add `strike-history.json` (and `*.tmp`) to `relay/.gitignore` alongside
the deployment config.

## App Changes (`lib/lightning/lightning_service.dart`)

In `_onMessage`, handle the new type before the strike case:

```dart
if (type == 'backlog') {
  final strikes = (map['strikes'] as List)
      .map((s) => Strike(LatLng(...), DateTime.fromMillisecondsSinceEpoch(...)))
      .toList();
  _strikes.value = strikes;   // replace, then prune to the display window
  _prune();
  return;
}
```

No other app change: the map page and camera overlay both render from the
`strikes` signal, so seeding the signal seeds every consumer. Test mode is
untouched (no relay connection). Malformed backlog entries are skipped
individually so one bad strike can't blank the seed.

## File Changes

| File | Change |
|------|--------|
| `relay/src/history.js` | New — shared rolling buffer + box query + disk snapshot |
| `relay/src/server.js` | Accept `history`; send box-filtered backlog on subscribe |
| `relay/src/web.js` | Drop private buffer; seed from shared history |
| `relay/index.js` | Create history; feed it from the upstream callback; stop it on shutdown |
| `relay/config.default.yaml` | Add `history` section; remove `web.backlogMaxStrikes` |
| `relay/.gitignore` | Ignore the snapshot file and its temp sibling |
| `lib/lightning/lightning_service.dart` | Handle `backlog`: replace strike list |

## Risks

- **Backlog size to app clients** — a 250 km box during an active storm holds at
  most a few thousand strikes; one JSON message of that size is well within what
  the web front already sends (worldwide, 20k cap).
- **Store-replace racing live strikes** — a live strike broadcast *after* the
  backlog was built but *before* the app processed it would be overwritten by
  replace. Prevented by ordering: the relay sends the backlog synchronously in
  the subscribe handler, and websocket messages are delivered in order, so any
  later live strike arrives after the backlog message.
- **Config rename** — deployments overriding `web.backlogMaxStrikes` would
  silently lose their cap; mitigated by the code fallback.
- **Snapshot write churn** — at the default 10 s interval the relay rewrites up
  to ~1 MB during active weather; trivial for any disk, and the dirty-flag check
  means zero writes while no strikes arrive. A hard kill (`SIGKILL`, power loss)
  loses at most the last interval's strikes — acceptable for display data that
  expires in 5 minutes anyway.
- **Stale snapshot on long downtime** — entries are pruned against the strike's
  own timestamp on load, so a relay that was down for hours simply starts empty;
  no special casing needed.
