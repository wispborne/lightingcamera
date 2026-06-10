# Lightning Proximity Alerts

## Problem

The app only shows lightning while it's open — on the map, the camera overlay, or the mini map. A user who wants to photograph lightning has to notice the storm themselves and then open the app. By the time they do, the most photogenic part of the storm may have passed. There is no way to be told "lightning is happening near you right now" while the phone is in their pocket.

## Proposed Solution

Add an optional, off-by-default **lightning alerts** feature:

- A settings toggle enables alerts, with a configurable radius (how close a strike must be to trigger a notification).
- While enabled, a persistent Android foreground service keeps a connection to the lightning relay open — even when the app is backgrounded or swiped away — and watches incoming strikes.
- When a strike lands within the configured radius of the user's current location, the phone shows a system notification ("Lightning 8 km away"). Tapping it opens the app on the camera page.
- Notifications are rate-limited so an active storm produces one useful alert, not a buzz per strike.
- The service starts automatically on device boot if the user left alerts enabled.

## Scope

- New settings: alerts on/off, alert radius.
- Android foreground service hosting a relay connection and proximity check.
- System notifications with rate limiting and tap-to-open behavior.
- Required Android permissions (notifications, foreground service) and their request flow.
- Reuse of the existing `LightningService` relay logic inside the background isolate.

## Non-Goals

- iOS support (the app is Android-only).
- Alert sounds/vibration customization beyond the system notification channel defaults (users can adjust per-channel in Android settings).
- Severe-weather forecasting or storm-approach prediction — alerts fire on actual strikes only.
- Server-side push notifications. The relay stays a plain strike feed; all alert logic is on-device.

## Risks / Open Questions

- **Relay sessions per key**: while the app is open with alerts enabled, the device holds two relay connections (UI + alert service) under the same key. The relay is assumed to allow this; if it enforces one session per key, the relay needs a small change or the service must hand off when the app foregrounds.
- **Battery**: a persistent connection plus coarse location costs battery. Mitigated by being opt-in, using low-accuracy location with a large distance filter, and the relay's existing keepalive cadence.
- **OEM battery managers** (Samsung, Xiaomi, etc.) may still kill the service despite foreground status. Out of our control; the notification channel doubles as a visible signal the service is alive.
