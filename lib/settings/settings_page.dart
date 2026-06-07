import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'settings_manager.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Shutter button position'),
            subtitle: const Text('Tap to reposition on camera view'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              settingsManager.enterRepositionMode();
              context.pop();
            },
          ),
        ],
      ),
    );
  }
}
