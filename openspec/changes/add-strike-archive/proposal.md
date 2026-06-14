# Strike Archive

## Problem

The relay sees every strike the upstream feed carries, but it only keeps the last
5 minutes of them (the in-memory rolling history, capped at 20 000). Once a strike
ages out of that window it is gone forever. There is no long-term record to look
back on — no way to ask "how many strikes hit this area last week" or to plot a
storm after the fact.

The relay runs on a laptop with a roomy external SSD, so there is space to keep a
permanent record. What's missing is somewhere to put it and a shape that stays
small and stays queryable.

## Proposed Solution

Add an optional, off-by-default **strike archive**: a single SQLite database on the
SSD that every recorded strike is written to, on top of the existing in-memory
history (which is untouched).

- Strikes are buffered in memory and written in batches (one transaction every few
  seconds, or sooner once a batch fills) — losing the last few seconds on a hard
  crash is acceptable; the point is that everything lands eventually.
- Storage is compact: latitude and longitude are stored as scaled integers and the
  database is a single file, so a year of the worldwide feed stays in the tens of
  gigabytes.
- It is queryable from day one: it's a plain SQLite file, so any SQLite tool can
  read it, and the change ships a tiny query helper for common questions (counts,
  time ranges, bounding boxes). A richer visualization can be built on top later.
- It uses Node's built-in `node:sqlite`, so the relay gains **no** new npm
  dependencies (still just `ws` + `yaml`).

## Scope

- A new `archive` module that owns the SQLite database, batched writes, and reads.
- A new `archive` section in the relay config (path on the SSD, flush cadence,
  batch size, enable flag).
- Wiring in `index.js` so every recorded strike is also handed to the archive.
- A small standalone query script for ad-hoc questions against the archive.
- README coverage of the new capability and config.

## Non-Goals

- Changing the in-memory rolling history or the live fan-out to clients — the
  archive is a passive sink alongside them.
- Real-time durability. Batched writes mean a crash can drop the last few seconds;
  that is an accepted trade for fewer, larger writes.
- A visualization UI or HTTP query API. The archive only has to be queryable; the
  visualization is explicitly a later, separate change.
- Automatic retention / pruning. The intent is to keep everything; a cap can be
  added later if disk ever becomes a concern.
- De-duplication or back-filling missed strikes during an outage — the archive
  records what the relay actually receives.

## Risks / Open Questions

- **Node version:** `node:sqlite` needs Node 22.5+ and prints an experimental
  warning. The relay runs on hardware the user controls, so this is acceptable; the
  archive is imported lazily so the warning only appears when archiving is enabled.
- **SSD unplugged / path missing:** if the database can't be opened or written, the
  relay must keep running and fanning out strikes — archiving fails soft (logged,
  disabled) rather than taking the relay down.
- **Volume:** the relay sees the whole worldwide feed (~1–2 M strikes/day). The
  compact row layout keeps this manageable on the SSD, but it is worth stating the
  expected growth so it isn't a surprise.
