import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightingcamera/camera/yuv_conversion_pool.dart';

void main() {
  // Tag each request by its width so we can observe processing order.
  YuvConversionRequest req(int tag) =>
      YuvConversionRequest.fromValues(width: tag, height: 1);

  test('high priority requests jump ahead of queued normal ones', () async {
    final gate = Completer<void>();
    final order = <int>[];
    var first = true;

    final pool = YuvConversionPool.withProcessor((request) async {
      if (first) {
        first = false;
        await gate.future; // hold the single lane busy while we queue more
      }
      order.add(request.width);
      return YuvConversionResult(Uint8List(0), request.width, request.height);
    }, workerCount: 1);

    final running = pool.convert(req(0), priority: ConversionPriority.normal);
    final normal = pool.convert(req(1), priority: ConversionPriority.normal);
    final high = pool.convert(req(2), priority: ConversionPriority.high);

    gate.complete();
    await Future.wait([running, normal, high]);

    // 0 was already running; then high (2) beats the earlier-queued normal (1).
    expect(order, [0, 2, 1]);
  });

  test('cancelPending fails queued requests but lets the running one finish',
      () async {
    final gate = Completer<void>();
    var first = true;

    final pool = YuvConversionPool.withProcessor((request) async {
      if (first) {
        first = false;
        await gate.future;
      }
      return YuvConversionResult(Uint8List(0), request.width, request.height);
    }, workerCount: 1);

    final running = pool.convert(req(0)); // occupies the lane
    final queued = pool.convert(req(1)); // waits behind it

    pool.cancelPending();
    await expectLater(queued, throwsA(isA<YuvCancelledException>()));

    gate.complete();
    final result = await running;
    expect(result.width, 0); // the in-flight request still completed
  });

  group('packYuv420ToNv21', () {
    test('scale 1 strips Y row padding and interleaves V/U', () {
      // 4×2 image, Y rows padded to a stride of 6.
      final y = Uint8List.fromList([
        1, 2, 3, 4, 99, 99, //
        5, 6, 7, 8, 99, 99,
      ]);
      // 2×1 chroma plane, planar (pixel stride 1).
      final u = Uint8List.fromList([10, 11]);
      final v = Uint8List.fromList([20, 21]);
      final req = YuvConversionRequest.fromValues(
        kind: ConversionKind.nv21,
        yPlane: y,
        uPlane: u,
        vPlane: v,
        width: 4,
        height: 2,
        yRowStride: 6,
        uvRowStride: 2,
        uvPixelStride: 1,
      );

      expect(nv21DimsFor(req), (4, 2));
      expect(
        packYuv420ToNv21(req),
        [1, 2, 3, 4, 5, 6, 7, 8, 20, 10, 21, 11],
      );
    });

    test('scale 2 subsamples luma and chroma', () {
      // 4×4 image downscaled to 2×2. Y rows padded to a stride of 5.
      final y = Uint8List.fromList([
        0, 1, 2, 3, 99, //
        4, 5, 6, 7, 99,
        8, 9, 10, 11, 99,
        12, 13, 14, 15, 99,
      ]);
      // 2×2 chroma plane, semi-planar (pixel stride 2): samples at offsets
      // 0 and 2 per row.
      final u = Uint8List.fromList([10, 0, 11, 0, 12, 0, 13, 0]);
      final v = Uint8List.fromList([20, 0, 21, 0, 22, 0, 23, 0]);
      final req = YuvConversionRequest.fromValues(
        kind: ConversionKind.nv21,
        yPlane: y,
        uPlane: u,
        vPlane: v,
        width: 4,
        height: 4,
        yRowStride: 5,
        uvRowStride: 4,
        uvPixelStride: 2,
        scale: 2,
      );

      expect(nv21DimsFor(req), (2, 2));
      // Luma: every 2nd pixel of every 2nd row. Chroma: the single output
      // sample covers the whole 2×2 output and reads source sample (0, 0).
      expect(packYuv420ToNv21(req), [0, 2, 8, 10, 20, 10]);
    });

    test('scaled dimensions round down to even', () {
      final req = YuvConversionRequest.fromValues(
        kind: ConversionKind.nv21,
        yPlane: Uint8List(10 * 7),
        uPlane: Uint8List(5 * 4),
        vPlane: Uint8List(5 * 4),
        width: 10,
        height: 7,
        yRowStride: 10,
        uvRowStride: 5,
        uvPixelStride: 1,
        scale: 3,
      );

      // 10÷3 = 3 and 7÷3 = 2, with the odd 3 rounded down to 2.
      expect(nv21DimsFor(req), (2, 2));
      final packed = packYuv420ToNv21(req);
      expect(packed.length, 2 * 2 + 2); // Y plane + one V/U pair
    });
  });
}
