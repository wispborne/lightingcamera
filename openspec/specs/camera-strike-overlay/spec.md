# Camera Strike Overlay

A real-world-anchored overlay that draws recent lightning strikes on the live camera feed,
positioned by the phone's location and facing direction.

## Requirement: User can enable or disable the overlay

The overlay SHALL be controlled by a single persisted on/off setting, exposed both as a toggle
on the settings page and as a quick toggle button on the camera page. Toggling either control
SHALL update the same setting, so the two stay in sync, and the setting SHALL persist across
app restarts. When the overlay is off, no marker or arrow is drawn and the overlay's
location/orientation work SHALL NOT run.

### Scenario: Toggle from the camera page
- **Given** the overlay is off
- **When** the user taps the camera-page overlay toggle button
- **Then** the overlay turns on and strikes begin to appear
- **And** the settings-page toggle reflects the on state

### Scenario: Toggle from the settings page
- **Given** the overlay is on
- **When** the user turns the settings-page toggle off
- **Then** returning to the camera shows no overlay
- **And** the camera-page toggle button reflects the off state

### Scenario: Setting persists across restarts
- **Given** the user has turned the overlay off
- **When** the app is restarted and the camera is reopened
- **Then** the overlay remains off

### Scenario: No work when disabled
- **Given** the overlay is off
- **When** the camera page is open
- **Then** no GPS fix or orientation subscription is started for the overlay

## Requirement: Show the five most recent strikes

The overlay SHALL display the 5 most recent strikes known to `lightningService`, ordered by
strike time. When fewer than 5 strikes are available, it shows all of them. When strikes age
out of the service's display window or new strikes arrive, the overlay updates to reflect the
current set.

### Scenario: Fewer than five strikes available
- **Given** the lightning service currently holds 3 strikes
- **When** the camera page is open
- **Then** the overlay shows markers/arrows for those 3 strikes and nothing more

### Scenario: A newer strike arrives
- **Given** 5 strikes are already shown
- **When** a newer strike arrives from the service
- **Then** the overlay drops the oldest of the 5 and shows the new one

## Requirement: Anchor markers to real-world direction

For each shown strike, the overlay SHALL compute the strike's real-world bearing and the
phone's current facing direction, and place the strike's marker at the corresponding point in
the viewfinder. As the phone's orientation changes, the marker position SHALL update so that
it remains fixed to the strike's real-world direction.

### Scenario: Strike within the field of view
- **Given** a strike lies within the camera's horizontal and vertical field of view
- **When** the user holds the phone pointing near it
- **Then** an in-place marker is drawn over the feed at the strike's screen position
- **And** the marker slides toward center as the user turns to face the strike

### Scenario: Phone rotated about its view axis (roll)
- **Given** a strike is visible on screen
- **When** the user tilts the phone left or right (roll)
- **Then** the marker positions rotate with the horizon so they stay world-anchored

## Requirement: Indicate off-screen strikes with edge arrows

For each shown strike that falls outside the current field of view, the overlay SHALL draw an
arrow pinned to the edge of the screen, pointing in the direction the user should turn to
bring that strike into view. When the user turns enough that the strike enters the field of
view, its edge arrow SHALL be replaced by an in-place marker.

### Scenario: Strike behind the user
- **Given** a strike is directly behind the user
- **When** the camera is open
- **Then** an edge arrow points toward the shorter way to turn to face the strike
- **And** no in-place marker is drawn for it

### Scenario: Turning an off-screen strike into view
- **Given** a strike is shown as an edge arrow
- **When** the user turns to face its direction
- **Then** the edge arrow disappears and an in-place marker appears

## Requirement: Reflect strike age visually

Markers and edge arrows SHALL convey each strike's age using the same age-based color and
fade scheme as the lightning map, so a fresh strike is visually distinct from an old one.

### Scenario: Old vs. fresh strike
- **Given** two shown strikes, one recent and one near the end of the display window
- **Then** the recent strike is rendered more prominently (color/opacity) than the older one

## Requirement: Degrade gracefully without sensors or location

When the phone's location or orientation sensors are unavailable or permission is denied, the
overlay SHALL NOT crash the camera and SHALL hide itself rather than drawing markers at wrong
positions. Normal camera capture continues unaffected.

### Scenario: Location permission denied
- **Given** location permission is denied
- **When** the camera page is open
- **Then** no strike markers or arrows are drawn
- **And** the live feed, caching, and shutter continue to work normally

### Scenario: Orientation sensor unavailable
- **Given** the device reports no usable orientation data
- **Then** the overlay hides its markers rather than placing them incorrectly
