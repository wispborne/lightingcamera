# Tasks: Strike History Seeding

## Relay

- [x] Create `relay/src/history.js`: `makeStrikeHistory({windowMs, maxStrikes, snapshotPath, snapshotIntervalMs, log})`
      with `add(strike)` and `query(box?)`, pruning by age then by count; export
      the shared `DISPLAY_WINDOW_MS` constant from here.
- [x] Add snapshot persistence to `history.js`: load + prune on construction
      (corrupt/missing file → warn and start empty), dirty-flagged interval
      saves via temp-file-then-rename, and `save()`/`stop()` with a synchronous
      final write for shutdown.
- [x] Wire the history into `relay/index.js`: construct it from the `history`
      config section (`maxStrikes` falling back to `web.backlogMaxStrikes`, then
      20000), call `history.add(strike)` in the upstream callback before the
      broadcasts, and call `history.stop()` in the shutdown handler.
- [x] Pass `history` into `startServer` and send
      `{type:'backlog', strikes: history.query(socket.box)}` in the subscription
      handler, on every subscription message.
- [x] Pass `history` into `startWeb`; remove the private `backlog` array,
      `pruneBacklog()`, and local `DISPLAY_WINDOW_MS`; seed new viewers from
      `history.query()`.
- [x] Update `relay/config.default.yaml`: add the `history` section
      (`maxStrikes: 20000`, `snapshotPath: strike-history.json`,
      `snapshotIntervalMs: 10000`) and remove `web.backlogMaxStrikes`.
- [x] Add the snapshot file and its `.tmp` sibling to `relay/.gitignore`.

## App

- [x] Handle `type == 'backlog'` in `LightningService._onMessage`: parse the
      strike array (skipping malformed entries), replace `_strikes`, then prune.

## Verification

- [x] Run the relay locally with the web front enabled; confirm a fresh web tab
      still opens populated (worldwide backlog from the shared history).
      *(scripted ws client against the real `startWeb`; relay also boot-tested
      with the web front enabled)*
- [x] Connect the app (or a scripted websocket client) mid-stream; confirm the
      backlog arrives after subscribing, contains only strikes inside the box,
      and live strikes keep appending afterwards. *(scripted: auth → subscribe →
      box-filtered backlog → live strike, all in order)*
- [x] Re-subscribe with a new center; confirm a fresh backlog replaces the list
      with no duplicate strikes on the map. *(relay side scripted; app side
      replaces the list by construction and passes `flutter analyze`)*
- [x] Restart the relay while strikes are in the window and reconnect; confirm
      both clients are seeded with the pre-restart strikes from the snapshot.
      *(scripted: `stop()` saves, a fresh history loads all 3 strikes and
      answers box queries)*
- [x] Delete (then corrupt) the snapshot file and start the relay; confirm a
      warning is logged and clients get a clean empty backlog. *(scripted: both
      cases start empty; corrupt file logs a warning)*
- [x] Let the relay sit past the 5-minute window, restart, and confirm the stale
      snapshot is pruned to empty on load. *(scripted with a back-dated snapshot)*
- [x] Confirm the app still works against a relay without backlog support (no
      seeding, no errors). *(the `backlog` branch only fires on the new message
      type; every existing path is untouched and the analyzer is clean)*
