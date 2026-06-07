# Add Settings Page

## Problem

The app has no user-configurable preferences. The shutter button is hardcoded to center position, and there's no infrastructure to add future settings. As the app grows, users will need a way to customize behavior.

## Proposed Solution

Add a settings page accessible from a gear icon in the camera page's app bar. The first setting lets the user choose shutter button placement: **left** (default), **center**, or **right**.

Build a reusable settings architecture using `shared_preferences` for persistence and `signals` for reactive state (consistent with the existing codebase pattern). This architecture should make adding new settings trivial — define the key, default, and widget.

## Scope

- Settings page with gear icon navigation from camera page
- Shutter button position setting (left/center/right, default: left)
- `SettingsManager` singleton using signals + shared_preferences
- GoRouter route for the settings page (the `Pages.settings` name already exists)

## Non-Goals

- Settings sync across devices
- Settings export/import
- Complex settings categories or nested pages (can be added later)
