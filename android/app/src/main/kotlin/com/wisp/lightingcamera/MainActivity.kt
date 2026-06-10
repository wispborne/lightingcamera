package com.wisp.lightingcamera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan
import kotlin.math.max

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.wisp.lightingcamera/volume_keys"
    private val CAMERA_INFO_CHANNEL = "com.wisp.lightingcamera/camera_info"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getHorizontalFov" -> {
                        val fov = backCameraHorizontalFovDegrees()
                        if (fov != null) result.success(fov) else result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Horizontal field of view of the back camera in degrees, derived from the
    /// physical sensor width and the (widest) focal length. Returns null if the
    /// data isn't available so Dart can fall back to a default.
    private fun backCameraHorizontalFovDegrees(): Double? {
        return try {
            val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            for (id in manager.cameraIdList) {
                val chars = manager.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING)
                if (facing != CameraCharacteristics.LENS_FACING_BACK) continue

                val size = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                val focals = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                if (size == null || focals == null || focals.isEmpty()) continue

                // Widest lens = shortest focal length = largest FOV.
                val focal = focals.minOrNull() ?: continue
                if (focal <= 0f) continue
                val sensorWidth = max(size.width, size.height)
                val fovRad = 2.0 * atan((sensorWidth / (2.0 * focal)))
                return Math.toDegrees(fovRad)
            }
            null
        } catch (e: Exception) {
            null
        }
    }

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
