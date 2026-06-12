import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:lightingcamera/utils/photo_exif.dart';

import 'image_cache_manager.dart';
import 'image_converter.dart';
import '../native/yuv_converter_ffi.dart';

/// Background pool that runs all per-frame pixel work — YUV→RGBA conversion,
/// JPEG encoding, and NV21 packing — in long-lived worker isolates so the UI
/// thread never blocks on it.
///
/// A two-level idea drives it: requests carry a [ConversionPriority] (fullscreen
/// and saves jump ahead of bulk thumbnail work), and queued requests hold only
/// references to the cached frame's plane bytes — the bytes are copied across
/// the isolate boundary lazily, when a worker actually picks the task up, so a
/// full backlog of ~100 frames costs no extra memory.
final yuvConversionPool = YuvConversionPool();

enum ConversionPriority { high, normal, low }

enum ConversionKind { rgba, jpeg, nv21 }

/// The result handed back from a worker: RGBA bytes (for [ConversionKind.rgba]),
/// JPEG bytes (for [ConversionKind.jpeg]), or NV21 bytes (for
/// [ConversionKind.nv21]). [width]/[height] are the output dimensions of the
/// pixel buffer (post-rotation for RGBA).
class YuvConversionResult {
  YuvConversionResult(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

/// Thrown when a worker reports an error processing a request.
class YuvConversionException implements Exception {
  const YuvConversionException(this.message);
  final String message;
  @override
  String toString() => 'YuvConversionException: $message';
}

/// Completes a request's future when [YuvConversionPool.cancelPending] drops it
/// from the queue before a worker started it. Callers treat this as "no longer
/// needed" and ignore it.
class YuvCancelledException implements Exception {
  const YuvCancelledException();
  @override
  String toString() => 'YuvCancelledException';
}

/// A self-contained, isolate-sendable description of one conversion. Holds the
/// frame's plane bytes plus the strides/dimensions needed to convert them — no
/// `CameraImage` (whose native planes are not sendable).
class YuvConversionRequest {
  YuvConversionRequest._({
    required this.kind,
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.rotation,
    required this.scale,
    this.jpegInfo,
  });

  final ConversionKind kind;
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width;
  final int height;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final int rotation;
  final int scale;
  final JpegEncodeInfo? jpegInfo;

  /// A reduced-resolution RGBA thumbnail sized for the grid.
  factory YuvConversionRequest.thumbnail(ImageWithMetadata frame) =>
      _fromFrame(
        frame,
        kind: ConversionKind.rgba,
        scale: ImageConverter.thumbScaleFor(frame.image.width, frame.image.height),
      );

  /// A full-resolution RGBA frame for the fullscreen viewer.
  factory YuvConversionRequest.fullRes(ImageWithMetadata frame) =>
      _fromFrame(frame, kind: ConversionKind.rgba, scale: 1);

  /// A full-resolution JPEG with EXIF, encoded in the worker for saving.
  factory YuvConversionRequest.jpeg(ImageWithMetadata frame, JpegEncodeInfo info) =>
      _fromFrame(frame, kind: ConversionKind.jpeg, scale: 1, jpegInfo: info);

  /// NV21 bytes for feeding the frame to ML Kit's labeler, downscaled like a
  /// grid thumbnail — the labeler's model shrinks its input to ~224px anyway,
  /// so packing at full resolution buys no accuracy.
  factory YuvConversionRequest.nv21(ImageWithMetadata frame) => _fromFrame(
        frame,
        kind: ConversionKind.nv21,
        scale: ImageConverter.thumbScaleFor(frame.image.width, frame.image.height),
      );

  /// Builds a request from raw values directly. For tests only — production
  /// code uses the frame-based factories, which extract these from a
  /// [ImageWithMetadata].
  @visibleForTesting
  factory YuvConversionRequest.fromValues({
    ConversionKind kind = ConversionKind.rgba,
    Uint8List? yPlane,
    Uint8List? uPlane,
    Uint8List? vPlane,
    required int width,
    required int height,
    int? yRowStride,
    int uvRowStride = 0,
    int uvPixelStride = 1,
    int rotation = 0,
    int scale = 1,
    JpegEncodeInfo? jpegInfo,
  }) {
    final empty = Uint8List(0);
    return YuvConversionRequest._(
      kind: kind,
      yPlane: yPlane ?? empty,
      uPlane: uPlane ?? empty,
      vPlane: vPlane ?? empty,
      width: width,
      height: height,
      yRowStride: yRowStride ?? width,
      uvRowStride: uvRowStride,
      uvPixelStride: uvPixelStride,
      rotation: rotation,
      scale: scale,
      jpegInfo: jpegInfo,
    );
  }

  static YuvConversionRequest _fromFrame(
    ImageWithMetadata frame, {
    required ConversionKind kind,
    required int scale,
    JpegEncodeInfo? jpegInfo,
  }) {
    final ci = frame.image;
    final y = ci.planes[0];
    final u = ci.planes[1];
    final v = ci.planes[2];
    return YuvConversionRequest._(
      kind: kind,
      yPlane: y.bytes,
      uPlane: u.bytes,
      vPlane: v.bytes,
      width: ci.width,
      height: ci.height,
      yRowStride: y.bytesPerRow,
      uvRowStride: u.bytesPerRow,
      uvPixelStride: u.bytesPerPixel ?? 1,
      rotation: ImageConverter.rotationFor(frame.orientation, frame.lensDirection),
      scale: scale,
      jpegInfo: jpegInfo,
    );
  }
}

class YuvConversionPool {
  YuvConversionPool({int workerCount = 2})
      : _workerCount = workerCount,
        _testProcessor = null;

  /// Test seam: replaces the real isolate workers with an in-process
  /// [processor], invoked with at most [workerCount] calls in flight. Lets the
  /// queue priority and cancellation logic be exercised on a host where the
  /// native library can't load.
  YuvConversionPool.withProcessor(
    Future<YuvConversionResult> Function(YuvConversionRequest) processor, {
    int workerCount = 2,
  })  : _workerCount = workerCount,
        _testProcessor = processor;

  final int _workerCount;
  final Future<YuvConversionResult> Function(YuvConversionRequest)? _testProcessor;

  final Queue<_Task> _high = Queue();
  final Queue<_Task> _normal = Queue();
  final Queue<_Task> _low = Queue();

  final List<_Worker> _workers = [];
  final List<_Worker> _idleWorkers = [];
  final Map<int, _InFlight> _inFlight = {};
  Future<void>? _starting;

  int _activeLanes = 0; // test mode only
  int _nextId = 0;

  /// Converts [request] in the background, resolving when a worker finishes it.
  /// Completes with a [YuvCancelledException] if [cancelPending] drops it from
  /// the queue first.
  Future<YuvConversionResult> convert(
    YuvConversionRequest request, {
    ConversionPriority priority = ConversionPriority.normal,
  }) async {
    if (_testProcessor == null) {
      await _ensureWorkers();
    }
    final task = _Task(_nextId++, request, Completer<YuvConversionResult>());
    _queueFor(priority).add(task);
    _pump();
    return task.completer.future;
  }

  /// Drops every queued (not yet started) request, failing each with a
  /// [YuvCancelledException]. Requests already running on a worker are left to
  /// finish — callers discard their results via a generation guard.
  void cancelPending() {
    for (final q in [_high, _normal, _low]) {
      while (q.isNotEmpty) {
        final task = q.removeFirst();
        if (!task.completer.isCompleted) {
          task.completer.completeError(const YuvCancelledException());
        }
      }
    }
  }

  Queue<_Task> _queueFor(ConversionPriority p) => switch (p) {
        ConversionPriority.high => _high,
        ConversionPriority.normal => _normal,
        ConversionPriority.low => _low,
      };

  _Task? _takeTask() {
    if (_high.isNotEmpty) return _high.removeFirst();
    if (_normal.isNotEmpty) return _normal.removeFirst();
    if (_low.isNotEmpty) return _low.removeFirst();
    return null;
  }

  void _pump() {
    while (true) {
      final hasCapacity =
          _testProcessor != null ? _activeLanes < _workerCount : _idleWorkers.isNotEmpty;
      if (!hasCapacity) return;
      final task = _takeTask();
      if (task == null) return;
      _dispatch(task);
    }
  }

  void _dispatch(_Task task) {
    if (_testProcessor != null) {
      _activeLanes++;
      _testProcessor(task.request).then(
        (r) {
          if (!task.completer.isCompleted) task.completer.complete(r);
        },
        onError: (Object e, StackTrace st) {
          if (!task.completer.isCompleted) task.completer.completeError(e);
        },
      ).whenComplete(() {
        _activeLanes--;
        _pump();
      });
      return;
    }

    final worker = _idleWorkers.removeLast();
    worker.busy = true;
    _inFlight[task.id] = _InFlight(task, worker);
    worker.sendPort.send(<Object?>[task.id, task.request]);
  }

  Future<void> _ensureWorkers() {
    if (_workers.length >= _workerCount) return Future.value();
    return _starting ??= _spawnMissing();
  }

  Future<void> _spawnMissing() async {
    while (_workers.length < _workerCount) {
      final rp = ReceivePort();
      final ready = Completer<_Worker>();
      late final _Worker worker;
      rp.listen((message) {
        if (message is SendPort) {
          worker = _Worker(message, rp);
          ready.complete(worker);
        } else if (message == null) {
          // onExit sends null when the worker isolate terminates.
          _handleWorkerExit(worker);
        } else {
          _handleReply(message as List<Object?>);
        }
      });
      await Isolate.spawn(_yuvWorkerMain, rp.sendPort, onExit: rp.sendPort);
      final spawned = await ready.future;
      _workers.add(spawned);
      _idleWorkers.add(spawned);
    }
    _starting = null;
  }

  void _handleReply(List<Object?> message) {
    final id = message[0] as int;
    final inFlight = _inFlight.remove(id);
    if (inFlight == null) {
      _pump();
      return;
    }
    final worker = inFlight.worker;
    worker.busy = false;
    if (_workers.contains(worker)) _idleWorkers.add(worker);

    final bytes = message[1] as Uint8List?;
    final width = message[2] as int;
    final height = message[3] as int;
    final error = message[4] as String?;

    if (!inFlight.task.completer.isCompleted) {
      if (error != null) {
        inFlight.task.completer.completeError(YuvConversionException(error));
      } else {
        inFlight.task.completer.complete(YuvConversionResult(bytes!, width, height));
      }
    }
    _pump();
  }

  void _handleWorkerExit(_Worker worker) {
    worker.receivePort.close();
    _workers.remove(worker);
    _idleWorkers.remove(worker);

    final stuck = _inFlight.entries.where((e) => e.value.worker == worker).toList();
    for (final entry in stuck) {
      _inFlight.remove(entry.key);
      if (!entry.value.task.completer.isCompleted) {
        entry.value.task.completer
            .completeError(const YuvConversionException('worker isolate exited'));
      }
    }
    // Respawn the lost worker so any queued work resumes.
    unawaited(_ensureWorkers());
    _pump();
  }
}

class _Task {
  _Task(this.id, this.request, this.completer);
  final int id;
  final YuvConversionRequest request;
  final Completer<YuvConversionResult> completer;
}

class _InFlight {
  _InFlight(this.task, this.worker);
  final _Task task;
  final _Worker worker;
}

class _Worker {
  _Worker(this.sendPort, this.receivePort);
  final SendPort sendPort;
  final ReceivePort receivePort;
  bool busy = false;
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

void _yuvWorkerMain(SendPort mainPort) {
  final rp = ReceivePort();
  mainPort.send(rp.sendPort);
  rp.listen((message) {
    final list = message as List<Object?>;
    final id = list[0] as int;
    final req = list[1] as YuvConversionRequest;
    try {
      mainPort.send(_processRequest(id, req));
    } catch (e) {
      mainPort.send(<Object?>[id, null, 0, 0, e.toString()]);
    }
  });
}

List<Object?> _processRequest(int id, YuvConversionRequest req) {
  switch (req.kind) {
    case ConversionKind.rgba:
      final (w, h) = _outputDims(req);
      return [id, _convertRgba(req), w, h, null];
    case ConversionKind.jpeg:
      final (w, h) = _outputDims(req);
      final rgba = _convertRgba(req);
      final image = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: rgba.buffer,
        order: img.ChannelOrder.rgba,
      );
      final jpeg = encodeJpgWithInfo(image, req.jpegInfo!);
      return [id, jpeg, w, h, null];
    case ConversionKind.nv21:
      final (w, h) = nv21DimsFor(req);
      return [id, packYuv420ToNv21(req), w, h, null];
  }
}

Uint8List _convertRgba(YuvConversionRequest req) {
  return YuvConverterFFI.convertYuvToRgb(
    req.yPlane,
    req.uPlane,
    req.vPlane,
    width: req.width,
    height: req.height,
    yRowStride: req.yRowStride,
    uvRowStride: req.uvRowStride,
    uvPixelStride: req.uvPixelStride,
    rotation: req.rotation,
    scale: req.scale,
  );
}

(int, int) _outputDims(YuvConversionRequest req) {
  final scale = req.scale < 1 ? 1 : req.scale;
  final outW = req.width ~/ scale;
  final outH = req.height ~/ scale;
  final swap = req.rotation == 90 || req.rotation == 270;
  return swap ? (outH, outW) : (outW, outH);
}

/// Output dimensions of an NV21 pack: the source size divided by the request's
/// scale, rounded down to even so the half-resolution chroma plane lines up.
@visibleForTesting
(int, int) nv21DimsFor(YuvConversionRequest req) {
  final scale = req.scale < 1 ? 1 : req.scale;
  if (scale == 1) return (req.width, req.height);
  return ((req.width ~/ scale) & ~1, (req.height ~/ scale) & ~1);
}

/// Packs 3-plane YUV420 into a single NV21 buffer: the Y plane (row padding
/// stripped to width) followed by interleaved V/U chroma, downscaling by
/// `req.scale` by stepping over source samples. Mirrors what ML Kit expects;
/// ported from the lightning service so it runs off the UI thread.
@visibleForTesting
Uint8List packYuv420ToNv21(YuvConversionRequest req) {
  final scale = req.scale < 1 ? 1 : req.scale;
  final (width, height) = nv21DimsFor(req);
  final chromaWidth = (width + 1) ~/ 2;
  final chromaHeight = (height + 1) ~/ 2;

  final nv21 = Uint8List(width * height + 2 * chromaWidth * chromaHeight);

  final yBytes = req.yPlane;
  final yRowStride = req.yRowStride;
  int offset = 0;
  if (scale == 1 && yRowStride == width) {
    nv21.setRange(0, width * height, yBytes);
    offset = width * height;
  } else if (scale == 1) {
    for (int row = 0; row < height; row++) {
      final rowStart = row * yRowStride;
      nv21.setRange(offset, offset + width, yBytes, rowStart);
      offset += width;
    }
  } else {
    for (int row = 0; row < height; row++) {
      int src = row * scale * yRowStride;
      for (int col = 0; col < width; col++) {
        nv21[offset++] = yBytes[src];
        src += scale;
      }
    }
  }

  final uBytes = req.uPlane;
  final vBytes = req.vPlane;
  final uvRowStride = req.uvRowStride;
  final uvPixelStride = req.uvPixelStride;
  // Output chroma sample (row, col) covers output pixel (2col, 2row) → source
  // pixel (2·col·scale, 2·row·scale) → source chroma sample (col·scale,
  // row·scale), so the chroma grid steps by the same scale as luma.
  final uvColStep = uvPixelStride * scale;

  for (int row = 0; row < chromaHeight; row++) {
    int uvIndex = row * scale * uvRowStride;
    for (int col = 0; col < chromaWidth; col++) {
      nv21[offset++] = vBytes[uvIndex];
      nv21[offset++] = uBytes[uvIndex];
      uvIndex += uvColStep;
    }
  }

  return nv21;
}
