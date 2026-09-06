import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:signals/signals_flutter.dart';

import 'package:lightingcamera/settings/settings_manager.dart';

/// The basemap both maps draw strikes on.
///
/// The tile source is a setting rather than a constant, so the app can point at
/// a self-hosted tile server without that address living in the repo (see
/// [SettingsManager.tileUrl]). It defaults to OpenStreetMap, which needs no key,
/// so a fresh build works with no configuration.
///
/// When a custom server is set, OpenStreetMap stays configured as a fallback:
/// a private tile server is typically only reachable on a home network or VPN,
/// and a phone in a field should get a map rather than a blank grid.
class BasemapLayer extends StatelessWidget {
  const BasemapLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final url = settingsManager.tileUrl;
        final isDefault = url == SettingsManager.defaultTileUrl;
        return TileLayer(
          urlTemplate: url,
          // A fallback turns off flutter_map's in-memory tile cache, so only
          // pay that cost when there is actually something to fall back from.
          fallbackUrl: isDefault ? null : SettingsManager.defaultTileUrl,
          userAgentPackageName: 'com.wisp.lightingcamera',
        );
      },
    );
  }
}
