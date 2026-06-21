import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:signals/signals_flutter.dart';
import 'package:lightingcamera/lightning/alert_service_controller.dart';
import 'package:lightingcamera/lightning/lightning_service.dart';
import 'package:lightingcamera/utils/units.dart';
import 'settings_manager.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  final FocusNode _urlFocusNode = FocusNode();
  bool _obscureKey = true;
  bool _testing = false;
  String? _testResultMessage;
  bool _testSuccess = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: settingsManager.customRelayUrl,
    );
    _keyController = TextEditingController(
      text: settingsManager.relayKey,
    );
  }

  @override
  void dispose() {
    _saveUrl();
    _saveKey();
    _urlController.dispose();
    _keyController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  void _saveUrl() {
    settingsManager.setCustomRelayUrl(_urlController.text.trim());
    alertServiceController.notifySettingsChanged();
  }

  void _saveKey() {
    settingsManager.setRelayKey(_keyController.text.trim());
    alertServiceController.notifySettingsChanged();
  }

  Future<void> _testConnection() async {
    _saveUrl();
    _saveKey();
    setState(() {
      _testing = true;
      _testResultMessage = null;
    });

    final url = _urlController.text.trim().isEmpty
        ? LightningService.defaultRelayUrl
        : _urlController.text.trim();

    final (success, message) = await LightningService.testConnection(
      url,
      _keyController.text.trim(),
    );

    // Remember a URL the user typed that authenticated, for the suggestions
    // dropdown. Empty (the default relay) is ignored by the manager.
    if (success) {
      await settingsManager.recordSuccessfulRelayUrl(
        _urlController.text.trim(),
      );
    }

    if (mounted) {
      setState(() {
        _testing = false;
        _testSuccess = success;
        _testResultMessage = message;
      });
    }
  }

  /// Turn lightning alerts on or off. Enabling needs either a relay key or test
  /// mode (otherwise there's nothing to watch) and notification permission; if
  /// either is missing the toggle reverts with a brief explanation.
  Future<void> _toggleAlerts(bool enabled) async {
    if (!enabled) {
      await settingsManager.setLightningAlertsEnabled(false);
      await alertServiceController.stop();
      return;
    }

    final hasKey = settingsManager.relayKey.isNotEmpty;
    if (!hasKey && !settingsManager.lightningTestMode) {
      _showAlertsMessage(
        'Set a relay key (or turn on test mode) before enabling alerts.',
      );
      return;
    }

    // Persist first so the service's launch-time sync sees it enabled.
    await settingsManager.setLightningAlertsEnabled(true);
    final started = await alertServiceController.start();
    if (!started) {
      await settingsManager.setLightningAlertsEnabled(false);
      _showAlertsMessage(
        'Lightning alerts need notification permission to work.',
      );
    }
  }

  void _showAlertsMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// The relay URL field, wrapped in a [RawAutocomplete] so that focusing it
  /// drops down the URLs that have connected successfully before. With empty
  /// text it offers all recent URLs; once the user types it narrows by match.
  Widget _buildRelayUrlField(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: _urlController,
      focusNode: _urlFocusNode,
      optionsBuilder: (textValue) {
        final recents = settingsManager.recentRelayUrls;
        final query = textValue.text.trim().toLowerCase();
        if (query.isEmpty) return recents;
        return recents.where((u) => u.toLowerCase().contains(query));
      },
      onSelected: (selection) {
        _urlController.text = selection;
        _saveUrl();
        setState(() => _testResultMessage = null);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Custom relay URL',
            hintText: LightningService.defaultRelayUrl,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _urlController.clear();
                settingsManager.setCustomRelayUrl('');
                setState(() => _testResultMessage = null);
              },
            ),
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (_) {
            _saveUrl();
            onFieldSubmitted();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: MediaQuery.of(context).size.width - 32,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options.elementAt(index);
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.history),
                      title: Text(
                        option,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// A section heading in the settings list — a small primary-coloured label
  /// with consistent spacing above and below, used to group related settings.
  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          // ── Camera ──────────────────────────────────────────────────────
          // Everything about capturing and processing the phone's own frames.
          _sectionHeader('Camera'),
          ListTile(
            title: const Text('Shutter button position'),
            subtitle: const Text('Tap to reposition on camera view'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              settingsManager.enterRepositionMode();
              context.pop();
            },
          ),
          SignalBuilder(builder: (context) {
            final aspect = settingsManager.captureAspectSignal.value;
            return ListTile(
              title: const Text('Capture shape'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Wide is sharper; Tall shows more above and below at a '
                    'little less detail.',
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<CaptureAspect>(
                    segments: const [
                      ButtonSegment(
                        value: CaptureAspect.wide16x9,
                        label: Text('Wide 16:9'),
                      ),
                      ButtonSegment(
                        value: CaptureAspect.full4x3,
                        label: Text('Tall 4:3'),
                      ),
                    ],
                    selected: {aspect},
                    onSelectionChanged: (selection) =>
                        settingsManager.setCaptureAspect(selection.first),
                  ),
                ],
              ),
            );
          }),
          SignalBuilder(
            builder: (context) => SwitchListTile(
              title: const Text('Tag photos with location'),
              subtitle: const Text(
                'Save each photo with the current GPS location in its details. '
                'Needs location permission.',
              ),
              value: settingsManager.geotagPhotosSignal.value,
              onChanged: settingsManager.setGeotagPhotos,
            ),
          ),
          SignalBuilder(builder: (context) {
            final threshold = settingsManager.lightningThresholdSignal.value;
            return ListTile(
              title: const Text('Lightning sensitivity'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'How sure the detector must be to flag a captured frame as '
                    'lightning. Lower catches faint bolts (and more false '
                    'alarms); higher keeps only obvious strikes.',
                  ),
                  Slider(
                    value: threshold,
                    min: SettingsManager.minLightningThreshold,
                    max: SettingsManager.maxLightningThreshold,
                    divisions:
                        ((SettingsManager.maxLightningThreshold -
                                    SettingsManager.minLightningThreshold) *
                                20)
                            .round(),
                    label: '${(threshold * 100).round()}%',
                    onChanged: settingsManager.setLightningThreshold,
                  ),
                ],
              ),
              trailing: Text('${(threshold * 100).round()}%'),
            );
          }),

          // ── Display ─────────────────────────────────────────────────────
          _sectionHeader('Display'),
          SignalBuilder(builder: (context) {
            final units = settingsManager.unitSystemSignal.value;
            return ListTile(
              title: const Text('Distance units'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Units for strike distances on the overlay.'),
                  const SizedBox(height: 8),
                  SegmentedButton<UnitSystem>(
                    segments: const [
                      ButtonSegment(
                        value: UnitSystem.system,
                        label: Text('Auto'),
                      ),
                      ButtonSegment(
                        value: UnitSystem.metric,
                        label: Text('Metric'),
                      ),
                      ButtonSegment(
                        value: UnitSystem.imperial,
                        label: Text('Imperial'),
                      ),
                    ],
                    selected: {units},
                    onSelectionChanged: (selection) {
                      settingsManager.setUnitSystem(selection.first);
                      alertServiceController.notifySettingsChanged();
                    },
                  ),
                ],
              ),
            );
          }),

          // ── Lightning overlay ───────────────────────────────────────────
          // Real-world strikes shown on top of the live camera feed.
          _sectionHeader('Lightning overlay'),
          SignalBuilder(
            builder: (context) => SwitchListTile(
              title: const Text('Strike overlay'),
              subtitle: const Text(
                'Show recent strikes over the camera, pinned to their real-world '
                'direction. Uses location and the compass.',
              ),
              value: settingsManager.strikeOverlayEnabledSignal.value,
              onChanged: settingsManager.setStrikeOverlayEnabled,
            ),
          ),
          SignalBuilder(
            builder: (context) => SwitchListTile(
              title: const Text('Strike info labels'),
              subtitle: const Text(
                'Show distance and thunder arrival time next to each strike '
                'on the camera overlay.',
              ),
              value: settingsManager.showStrikeInfoSignal.value,
              onChanged: settingsManager.strikeOverlayEnabledSignal.value
                  ? settingsManager.setShowStrikeInfo
                  : null,
            ),
          ),
          SignalBuilder(builder: (context) {
            final enabled = settingsManager.strikeOverlayEnabledSignal.value;
            final distance = settingsManager.maxStrikeDistanceKmSignal.value;
            return ListTile(
              enabled: enabled,
              title: const Text('Overlay strike distance'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Hide strikes farther than this from the camera overlay. '
                    'The full map still shows every strike.',
                  ),
                  Slider(
                    value: distance,
                    min: SettingsManager.minStrikeDistanceKm,
                    max: SettingsManager.maxStrikeDistanceKm,
                    divisions:
                        (SettingsManager.maxStrikeDistanceKm -
                                SettingsManager.minStrikeDistanceKm)
                            ~/ 5,
                    label: '${distance.round()} km',
                    onChanged: enabled
                        ? settingsManager.setMaxStrikeDistanceKm
                        : null,
                  ),
                ],
              ),
              trailing: Text('${distance.round()} km'),
            );
          }),
          SignalBuilder(
            builder: (context) => SwitchListTile(
              title: const Text('Mini map'),
              subtitle: const Text(
                'Show a small live lightning map in the top-left of the camera. '
                'Uses location.',
              ),
              value: settingsManager.miniMapEnabledSignal.value,
              onChanged: settingsManager.setMiniMapEnabled,
            ),
          ),
          SignalBuilder(builder: (context) {
            final enabled = settingsManager.miniMapEnabledSignal.value;
            final opacity = settingsManager.miniMapOpacitySignal.value;
            return ListTile(
              enabled: enabled,
              title: const Text('Mini map opacity'),
              subtitle: Slider(
                value: opacity,
                min: 0.2,
                max: 1.0,
                divisions: 8,
                label: '${(opacity * 100).round()}%',
                onChanged: enabled ? settingsManager.setMiniMapOpacity : null,
              ),
              trailing: Text('${(opacity * 100).round()}%'),
            );
          }),

          // ── Alerts ──────────────────────────────────────────────────────
          _sectionHeader('Alerts'),
          SignalBuilder(
            builder: (context) => SwitchListTile(
              title: const Text('Lightning alerts'),
              subtitle: const Text(
                'Notify me when lightning strikes nearby, even with the app '
                'closed. Runs a background service and uses location.',
              ),
              value: settingsManager.lightningAlertsEnabledSignal.value,
              onChanged: _toggleAlerts,
            ),
          ),
          SignalBuilder(builder: (context) {
            final enabled = settingsManager.lightningAlertsEnabledSignal.value;
            final radius = settingsManager.alertRadiusKmSignal.value;
            final units = settingsManager.unitSystemSignal.value;
            final label = formatDistanceKm(radius, units);
            return ListTile(
              enabled: enabled,
              title: const Text('Alert radius'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Alert me only when a strike lands this close. This is '
                    'separate from the overlay\'s display distance.',
                  ),
                  Slider(
                    value: radius,
                    min: SettingsManager.minStrikeDistanceKm,
                    max: SettingsManager.maxStrikeDistanceKm,
                    divisions:
                        (SettingsManager.maxStrikeDistanceKm -
                                SettingsManager.minStrikeDistanceKm)
                            ~/ 5,
                    label: label,
                    onChanged: enabled
                        ? (value) {
                            settingsManager.setAlertRadiusKm(value);
                            alertServiceController.notifySettingsChanged();
                          }
                        : null,
                  ),
                ],
              ),
              trailing: Text(label),
            );
          }),
          SignalBuilder(builder: (context) {
            final enabled = settingsManager.lightningAlertsEnabledSignal.value;
            final minutes = settingsManager.alertCooldownMinutesSignal.value;
            final label = '${minutes.round()} min';
            return ListTile(
              enabled: enabled,
              title: const Text('Alert cooldown'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quiet time after an alert before another nearby strike '
                    'sounds again. A much closer strike still alerts right away.',
                  ),
                  Slider(
                    value: minutes,
                    min: SettingsManager.minAlertCooldownMinutes,
                    max: SettingsManager.maxAlertCooldownMinutes,
                    divisions:
                        (SettingsManager.maxAlertCooldownMinutes -
                                SettingsManager.minAlertCooldownMinutes)
                            .round(),
                    label: label,
                    onChanged: enabled
                        ? (value) {
                            settingsManager.setAlertCooldownMinutes(value);
                            alertServiceController.notifySettingsChanged();
                          }
                        : null,
                  ),
                ],
              ),
              trailing: Text(label),
            );
          }),

          // ── Relay ───────────────────────────────────────────────────────
          // Where strike data comes from, plus the test-mode simulator.
          _sectionHeader('Relay'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _buildRelayUrlField(context),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Leave empty to use the default relay.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: TextField(
              controller: _keyController,
              obscureText: _obscureKey,
              decoration: InputDecoration(
                labelText: 'Relay key',
                hintText: 'Key from whoever runs the relay',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  tooltip: _obscureKey ? 'Show key' : 'Hide key',
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
              onSubmitted: (_) => _saveKey(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Required to connect. Ask whoever runs the relay for your key.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onSecondaryContainer,
                          ),
                        )
                      : const Icon(Icons.sync),
                  label: const Text('Test connection'),
                ),
                if (_testResultMessage != null) ...[
                  const SizedBox(width: 16),
                  Icon(
                    _testSuccess ? Icons.check_circle : Icons.error,
                    size: 20,
                    color: _testSuccess
                        ? colorScheme.primary
                        : colorScheme.error,
                  ),
                ],
              ],
            ),
          ),
          if (_testResultMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                _testResultMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _testSuccess
                          ? colorScheme.primary
                          : colorScheme.error,
                    ),
              ),
            ),
          SignalBuilder(
            builder: (context) => SwitchListTile(
              title: const Text('Lightning test mode'),
              subtitle: const Text(
                'Simulate strikes every 5 seconds instead of using the relay. '
                'Reopen the map to apply.',
              ),
              value: settingsManager.lightningTestModeSignal.value,
              onChanged: (value) {
                settingsManager.setLightningTestMode(value);
                alertServiceController.notifySettingsChanged();
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
