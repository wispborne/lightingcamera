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
}
