# Rain Radar Overlay

Show the latest precipitation radar frame as a semi-transparent layer on the lightning map and the camera mini map, sourced from RainViewer's free public API.

## Requirements

### R1: Radar setting

A single **rain radar** on/off setting MUST control the radar layer on both maps. Default on. Persists across restarts (shared preferences, same pattern as other settings).

#### Acceptance
- Fresh install: radar layer shows on both maps (once a frame is available).
- Toggling off removes the layer from both maps immediately and stops index polling; toggling back on restores it without restarting the app.
- The setting survives an app restart.

### R2: Map page toggle

The lightning map page's app bar MUST expose the radar toggle, styled like the existing thunder-circles toggle (highlighted icon when on, dimmed when off, tooltip describing the action).

#### Acceptance
- Tapping the icon flips the setting; the layer appears/disappears on the open map without leaving the page.
- Icon state reflects the persisted setting when the page opens.

### R3: Latest frame fetching

While any map that can show radar is open and the setting is on, the app MUST keep track of the newest available radar frame.

#### Acceptance
- On first display, the frame index (`https://api.rainviewer.com/public/weather-maps.json`) is fetched and the newest `radar.past` frame is used.
- The index is re-fetched periodically (every 5 minutes) so the layer advances as new frames publish (~every 10 minutes).
- No index requests happen while the setting is off or no map is showing.
- A failed fetch is logged and retried at the next interval; the app never crashes or blocks on it.

### R4: Radar tile layer

Both maps MUST render the current frame as a tile layer between the base map and the lightning layers (thunder circles, strike markers stay on top).

#### Acceptance
- Radar tiles render semi-transparently so the base map stays readable underneath.
- The mini map's radar inherits the mini map's existing overall opacity on top of the layer's own transparency.
- Before the first index fetch completes (or after failure), the maps render exactly as they do today — no placeholder, no error chrome.

### R5: Staleness guard

The layer MUST NOT present outdated rain as current.

#### Acceptance
- If the newest known frame is more than 30 minutes old (e.g. the index endpoint has been failing), the layer hides until a fresher frame is fetched.

### R6: Web map parity

The worldwide web map (`relay/web`) MUST show the same latest-frame radar layer, with its own toggle. State persists in `localStorage` (default on).

#### Acceptance
- A "Radar" toggle sits alongside the existing Thunder/Sound controls, highlighting when on.
- The radar tiles render beneath the strike canvas so lightning stays on top, semi-transparent over the dark base map.
- Same 5-minute refresh and 30-minute staleness guard as the app.
- A failed fetch keeps the last frame and retries silently; the map never blocks.
- RainViewer attribution shows in the Leaflet attribution control while the layer is on.
- An opacity slider (0–1) appears while radar is on and adjusts the layer live; its value persists in `localStorage` (default 0.3).

### R7: Attribution

While the radar layer is visible on the full map page, a small "Radar © RainViewer" credit MUST be shown, unobtrusively (e.g. caption text near the map edge). The mini map, being a tiny thumbnail, is exempt.

#### Acceptance
- Credit visible on the map page when the layer is on and a frame is loaded; absent when the layer is off or hidden.
