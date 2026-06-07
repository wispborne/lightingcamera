import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

final settingsManager = SettingsManager();

class SettingsManager {
  static const _shutterOffsetXKey = 'shutter_offset_x';

  late final Signal<double> _shutterOffsetX;
  ReadonlySignal<double> get shutterOffsetXSignal => _shutterOffsetX;
  double get shutterOffsetX => _shutterOffsetX.value;

  late final Signal<bool> _isRepositioning;
  ReadonlySignal<bool> get isRepositioningSignal => _isRepositioning;
  bool get isRepositioning => _isRepositioning.value;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_shutterOffsetXKey) ?? 0.0;
    _shutterOffsetX = signal(stored);
    _isRepositioning = signal(false);
  }

  Future<void> setShutterOffsetX(double offset) async {
    _shutterOffsetX.value = offset.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_shutterOffsetXKey, _shutterOffsetX.value);
  }

  void enterRepositionMode() {
    _isRepositioning.value = true;
  }

  void exitRepositionMode() {
    _isRepositioning.value = false;
  }
}
