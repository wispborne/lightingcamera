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
      Int32 uvRowStride,
      Int32 uvPixelStride,
    );

typedef ConvertYuvToRgbDart =
    void Function(
      Pointer<Uint8> yPlane,
      Pointer<Uint8> uPlane,
      Pointer<Uint8> vPlane,
      Pointer<Uint8> rgbOutput,
      int width,
      int height,
      int uvRowStride,
      int uvPixelStride,
    );

class YuvConverterFFI {
  static DynamicLibrary? _library;
  static ConvertYuvToRgbDart? _convertYuvToRgb;

  // Load the native library
  static void _loadLibrary() {
    if (_library != null) return;

    if (Platform.isAndroid) {
      _library = DynamicLibrary.open('libyuv_converter.so');
    } else if (Platform.isIOS) {
      _library = DynamicLibrary.process();
    } else {
      throw UnsupportedError('Platform not supported');
    }

    _convertYuvToRgb =
        _library!
            .lookup<NativeFunction<ConvertYuvToRgbNative>>('convert_yuv_to_rgb')
            .asFunction<ConvertYuvToRgbDart>();
  }

  // Convert YUV to RGB using native code
  static Uint8List convertYuvToRgb(
    Uint8List yPlane,
    Uint8List uPlane,
    Uint8List vPlane,
    int width,
    int height,
    int uvRowStride,
    int uvPixelStride,
  ) {
    _loadLibrary();

    // Use an Arena for automatic memory management
    // Memory allocated within the arena is freed when the arena is disposed
    final arena = Arena();
    try {
      // Allocate native memory within the arena
      final yPointer = arena<Uint8>(yPlane.length);
      final uPointer = arena<Uint8>(uPlane.length);
      final vPointer = arena<Uint8>(vPlane.length);
      final rgbPointer = arena<Uint8>(width * height * 3);

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
        uvRowStride,
        uvPixelStride,
      );

      // Copy result back to Dart
      return Uint8List.fromList(rgbPointer.asTypedList(width * height * 3));
    } finally {
      // Dispose the arena to free all allocated memory
      arena.releaseAll();
    }
  }
}
