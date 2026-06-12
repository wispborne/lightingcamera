import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightingcamera/camera/image_converter.dart';

void main() {
  group('thumbScaleFor', () {
    test('targets ~360px on the short side', () {
      expect(ImageConverter.thumbScaleFor(1920, 1080), 3); // 1080 / 360
      expect(ImageConverter.thumbScaleFor(1080, 1920), 3); // orientation agnostic
      expect(ImageConverter.thumbScaleFor(1280, 720), 2); // 720 / 360
      expect(ImageConverter.thumbScaleFor(4000, 3000), 8); // 3000 / 360
    });

    test('never drops below 1, even for small frames', () {
      expect(ImageConverter.thumbScaleFor(640, 480), 1); // 480 / 360 -> 1
      expect(ImageConverter.thumbScaleFor(360, 360), 1);
      expect(ImageConverter.thumbScaleFor(320, 240), 1); // would be 0, clamped
    });
  });

  group('rotationFor', () {
    test('normalizes to 0/90/180/270 and is never negative', () {
      for (final lens in CameraLensDirection.values) {
        for (final orientation in DeviceOrientation.values) {
          final angle = ImageConverter.rotationFor(orientation, lens);
          expect(const {0, 90, 180, 270}.contains(angle), isTrue,
              reason: '$lens/$orientation produced $angle');
        }
      }
    });

    test('back camera angles', () {
      const back = CameraLensDirection.back;
      expect(ImageConverter.rotationFor(DeviceOrientation.portraitUp, back), 90);
      // portraitDown used to send -90, which the native switch dropped to 0.
      expect(ImageConverter.rotationFor(DeviceOrientation.portraitDown, back), 270);
      expect(ImageConverter.rotationFor(DeviceOrientation.landscapeLeft, back), 0);
      expect(ImageConverter.rotationFor(DeviceOrientation.landscapeRight, back), 180);
    });

    test('front camera angles mirror the back camera', () {
      const front = CameraLensDirection.front;
      expect(ImageConverter.rotationFor(DeviceOrientation.portraitUp, front), 270);
      expect(ImageConverter.rotationFor(DeviceOrientation.portraitDown, front), 90);
      expect(ImageConverter.rotationFor(DeviceOrientation.landscapeLeft, front), 0);
      expect(ImageConverter.rotationFor(DeviceOrientation.landscapeRight, front), 180);
    });
  });
}
