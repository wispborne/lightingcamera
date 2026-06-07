package com.wisp.lightingcamera

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.wisp.lightingcamera/volume_keys"

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            flutterEngine?.dartExecutor?.binaryMessenger?.let {
                MethodChannel(it, CHANNEL).invokeMethod(
                    "volumeKeyPressed",
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down"
                )
            }
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
