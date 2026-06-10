# Lightning Proximity Alerts

Notify the user when lightning strikes within a configurable distance of their location, including while the app is backgrounded or closed.

## Requirements

### R1: Opt-in setting

The feature MUST be off by default. Settings exposes:
- **Lightning alerts** toggle.
- **Alert radius** slider, 5–100 km, default 15 km, only enabled while the toggle is on.

Both persist across restarts (shared preferences, same pattern as other settings).

#### Acceptance
- Fresh install: alerts off, no service running, no notification permission requested.
- Toggling on requests needed permissions; if the user denies notification permission, the toggle reverts to off with a brief explanation.
- Radius changes take effect without restarting the service or the app.

### R2: Background monitoring

While alerts are enabled, a foreground service MUST keep a relay connection alive and evaluate strikes, independent of the app's UI lifecycle.

#### Acceptance
- Alerts continue to fire with the app backgrounded and after it is swiped away from recents.
- The service shows the mandatory persistent notification (low priority, silent) indicating monitoring is active.
- Disabling the toggle stops the service and removes the persistent notification.
- After device reboot, the service restarts on its own if alerts were enabled.
- If no relay key is configured, the toggle warns the user and the service does not start.

### R3: Proximity notification

When a strike arrives whose distance to the user's last known location is within the alert radius, the device MUST show a notification.

#### Acceptance
- Notification states the distance (e.g. "Lightning 8 km away") and the strike's bearing as a compass direction (e.g. "to the northwest") when location is available.
- Tapping the notification opens the app on the camera page.
- Strikes outside the radius produce no notification.
- Works with lightning test mode: simulated strikes within the radius trigger notifications, allowing the feature to be verified without a storm.

### R4: Rate limiting

An active storm MUST NOT spam the user.

#### Acceptance
- After an alert fires, further qualifying strikes within a 5-minute cooldown update the existing notification silently (no new sound/vibration) instead of posting a new one.
- A strike markedly closer than the one that triggered the last alert (at most half its distance) MAY bypass the cooldown once, so an approaching storm re-alerts.

### R5: Location handling

The service MUST track the user's location coarsely and degrade gracefully.

#### Acceptance
- Location updates use low accuracy and a large distance filter (≥ 2 km), matching the existing lightning service behavior.
- If location permission is missing or no fix is available, the service uses the last known location; with none at all, it stays connected but fires no alerts and the persistent notification says location is unavailable.
