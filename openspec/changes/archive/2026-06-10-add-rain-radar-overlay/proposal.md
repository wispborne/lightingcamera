# Rain Radar Overlay

## Problem

The lightning map shows where strikes are landing, but not where the rain is. For someone deciding where to point a camera — or whether a storm is heading toward them — precipitation is the missing half of the picture. Strikes alone don't show the storm's shape, extent, or direction of travel. Users currently have to switch to a separate weather app and mentally line the two maps up.

## Proposed Solution

Overlay live precipitation radar tiles on both maps:

- **Source: RainViewer's free public weather maps API.** No API key, global coverage, new composite frame roughly every 10 minutes. Verified live and free as of 2026-06-10 (the API's nowcast portion was discontinued, but past-radar tiles — all we need — remain available for personal/small-scale use with attribution).
- **Latest frame only.** The newest available radar frame is shown as a semi-transparent tile layer; there is no animation timeline or history scrubbing.
- **Every map.** The full lightning map page, the camera page's mini map, and the worldwide web map (`relay/web`) render the same radar layer.
- **Persisted toggle.** A single radar on/off setting (default on) is stored alongside the other settings and controls both maps. The full map gets an app-bar toggle, matching the existing thunder-circles toggle.
- A small "Radar © RainViewer" attribution shows on the full map while the layer is visible, per RainViewer's usage terms.

## Scope

- New `RainRadarService` that fetches RainViewer's frame index on a timer and exposes the newest frame's tile URL.
- Radar tile layer on the lightning map page and the mini map.
- New persisted setting (`rain_radar_enabled`) and app-bar toggle on the map page.
- Attribution text on the full map.
- The same radar layer + toggle on the worldwide web map (`relay/web`), where the toggle state persists in `localStorage` (the web client has no shared-preferences store).

## Non-Goals

- Frame animation / time scrubbing (latest frame only — explicit decision).
- Forecast or nowcast precipitation (RainViewer no longer provides it; past frames only).
- Satellite/infrared layers.
- Per-map radar toggles or radar opacity settings — one shared on/off switch.
- Offline caching of radar tiles beyond what the map library already does in memory.

## Risks / Open Questions

- **Free API longevity**: RainViewer discontinued parts of its API in January 2026 and keeps the rest on a no-guarantees basis. The feature must degrade gracefully (layer simply absent) if the API disappears, and the service is the single place to swap in a different tile source later.
- **Radar coverage gaps**: RainViewer composites ground radar, so oceans and some regions show no data even during rain. Acceptable — absence of radar just means absence of the overlay there.
- **Stale frames**: if index refresh fails repeatedly, old tile URLs eventually stop resolving. Mitigated by hiding the layer when the newest known frame is more than 30 minutes old.
