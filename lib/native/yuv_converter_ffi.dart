import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Define the C function signature
typedef ConvertYuvToRgbNative =
    Void Function(
      Pointer<Uint8> yPlane,
      Pointer<Uint8> uPlane,
      Pointer<Uint8> vPlane,
      Pointer<Uint8> rgbOutput,
      Int32 width,
      Int32 height,
      Int32 yRowStride,
      Int32 uvRowStride,
      Int32 uvPixelStride,
      Int32 rotation,
      Int32 scale,
    );

typedef ConvertYuvToRgbDart =
    void Function(
      Pointer<Uint8> yPlane,
      Pointer<Uint8> uPlane,
      Pointer<Uint8> vPlane,
      Pointer<Uint8> rgbOutput,
      int width,
      int height,
      int yRowStride,
      int uvRowStride,
      int uvPixelStride,
      int rotation,
      int scale,
    );

class YuvConverterFFI {
  static DynamicLibrary? _library;
  static ConvertYuvToRgbDart? _convertYuvToRgb;

  // Load the native library. Statics are per-isolate, so each background
  // worker that calls this opens its own handle to the shared library on
  // first use — there is no cross-isolate state to coordinate.
  static void _loadLibrary() {
    if (_library != null) return;

    if (Platform.isAndroid) {
      _library = DynamicLibrary.open('libyuv_converter.so');
    } else if (Platform.isIOS) {
      _library = DynamicLibrary.process();
    } else {
      throw UnsupportedError('Platform not supported');
    }

    _convertYuvToRgb = _library!
        .lookup<NativeFunction<ConvertYuvToRgbNative>>('convert_yuv_to_rgb_scaled')
        .asFunction<ConvertYuvToRgbDart>();
  }

  /// Converts YUV420 planes to an RGBA byte buffer using the native code,
  /// optionally downscaling by [scale] (1 = full resolution) and rotating by
  /// [rotation] (0/90/180/270, already normalized). Returns RGBA bytes sized
  /// `(width ~/ scale) * (height ~/ scale) * 4` — the rotation only swaps the
  /// width/height of that buffer, never its size.
  static Uint8List convertYuvToRgb(
    Uint8List yPlane,
    Uint8List uPlane,
    Uint8List vPlane, {
    required int width,
    required int height,
    required int yRowStride,
    required int uvRowStride,
    required int uvPixelStride,
    required int rotation,
    int scale = 1,
  }) {
    _loadLibrary();

    final int s = scale < 1 ? 1 : scale;
    final int outWidth = width ~/ s;
    final int outHeight = height ~/ s;
    final int outBytes = outWidth * outHeight * 4;

    // Use an Arena for automatic memory management — everything allocated here
    // is freed when the arena is released in the finally block.
    final arena = Arena();
    try {
      final yPointer = arena<Uint8>(yPlane.length);
      final uPointer = arena<Uint8>(uPlane.length);
      final vPointer = arena<Uint8>(vPlane.length);
      final rgbPointer = arena<Uint8>(outBytes);

      // Copy data to native memory
      yPointer.asTypedList(yPlane.length).setAll(0, yPlane);
      uPointer.asTypedList(uPlane.length).setAll(0, uPlane);
      vPointer.asTypedList(vPlane.length).setAll(0, vPlane);

      // Call native function
      _convertYuvToRgb!(
        yPointer,
        uPointer,
        vPointer,
        rgbPointer,
        width,
        height,
        yRowStride,
        uvRowStride,
        uvPixelStride,
        rotation,
        s,
      );

      // Copy result back to Dart
      return Uint8List.fromList(rgbPointer.asTypedList(outBytes));
    } finally {
      arena.releaseAll();
    }
  }
}
