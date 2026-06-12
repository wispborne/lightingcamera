import 'package:flutter/services.dart';

/// Singleton owner of the native volume-key channel.
///
/// `MainActivity.onKeyDown` forwards every hardware volume press over the
/// `com.wisp.lightingcamera/volume_keys` channel. Only one method-call handler
/// can be attached to a channel at a time, so if two pages each called
/// `setMethodCallHandler` the second would silently steal the keys from the
/// first. This dispatcher owns the handler once and fans presses out to a
/// **stack** of listeners — only the top (most recently subscribed) listener
/// hears a press, so whichever page is on top of the navigation stack receives
/// the keys and the one beneath it does not.
final volumeKeyDispatcher = VolumeKeyDispatcher();

class VolumeKeyDispatcher {
  static const _channel = MethodChannel(
    'com.wisp.lightingcamera/volume_keys',
  );

  final List<void Function()> _listeners = [];
  bool _handlerAttached = false;

  /// Register [listener] as the new top of the stack. While it stays on top it
  /// receives every volume press. Call [unsubscribe] (typically in `dispose`)
  /// to remove it.
  void subscribe(void Function() listener) {
    if (!_handlerAttached) {
      _channel.setMethodCallHandler(_handleCall);
      _handlerAttached = true;
    }
    _listeners.add(listener);
  }

  /// Remove [listener] from the stack. Safe to call for a listener that is not
  /// on top (out-of-order disposal) or that was never subscribed.
  void unsubscribe(void Function() listener) {
    _listeners.remove(listener);
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'volumeKeyPressed' && _listeners.isNotEmpty) {
      _listeners.last();
    }
  }
}
