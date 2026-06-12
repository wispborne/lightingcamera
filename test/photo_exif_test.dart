import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:lightingcamera/utils/photo_exif.dart';

void main() {
  Position fakePosition({
    double latitude = 37.422,
    double longitude = -122.084,
    double altitude = 12.5,
    double heading = 90.0,
  }) {
    return Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.utc(2026, 6, 11, 14, 30, 15),
      accuracy: 5,
      altitude: altitude,
      altitudeAccuracy: 3,
      heading: heading,
      headingAccuracy: 1,
      speed: 0,
      speedAccuracy: 0,
    );
  }

  test('writes GPS and common EXIF that round-trips through the JPEG', () {
    final image = img.Image(width: 4, height: 4);
    final bytes = encodeJpgWithMetadata(
      image,
      timestamp: DateTime(2026, 6, 11, 14, 30, 15),
      position: fakePosition(),
      make: 'Google',
      model: 'Pixel 9 Pro',
    );

    final decoded = img.decodeJpg(bytes)!;
    final exif = decoded.exif;

    // Common identifying tags.
    expect(exif.imageIfd['Make']?.toString(), 'Google');
    expect(exif.imageIfd['Model']?.toString(), 'Pixel 9 Pro');
    expect(exif.imageIfd['Software']?.toString(), 'Lightning Camera');
    expect(exif.imageIfd['DateTime']?.toString(), '2026:06:11 14:30:15');
    expect(exif.exifIfd['DateTimeOriginal']?.toString(), '2026:06:11 14:30:15');

    // GPS: north + west hemispheres, three-part coordinates.
    final gps = exif.gpsIfd;
    expect(gps['GPSLatitudeRef']?.toString(), 'N');
    expect(gps['GPSLongitudeRef']?.toString(), 'W');
    expect(gps['GPSLatitude']?.length, 3);
    expect(gps['GPSLongitude']?.length, 3);

    // Latitude 37.422 -> 37° 25' ~19.2"
    final lat = gps['GPSLatitude']!;
    expect(lat.toRational(0).toDouble(), 37);
    expect(lat.toRational(1).toDouble(), 25);
    expect(lat.toRational(2).toDouble(), closeTo(19.2, 0.01));

    // Altitude and heading present.
    expect(gps['GPSAltitude']?.toDouble(), closeTo(12.5, 0.01));
    expect(gps['GPSImgDirection']?.toDouble(), closeTo(90.0, 0.01));
    expect(gps[0x1d]?.toString(), '2026:06:11'); // GPSDateStamp
  });

  test('southern/eastern hemisphere refs flip correctly', () {
    final bytes = encodeJpgWithMetadata(
      img.Image(width: 2, height: 2),
      timestamp: DateTime(2026, 1, 1),
      position: fakePosition(latitude: -33.86, longitude: 151.20),
    );
    final gps = img.decodeJpg(bytes)!.exif.gpsIfd;
    expect(gps['GPSLatitudeRef']?.toString(), 'S');
    expect(gps['GPSLongitudeRef']?.toString(), 'E');
  });

  test('omits GPS when no position is supplied but keeps other tags', () {
    final bytes = encodeJpgWithMetadata(
      img.Image(width: 2, height: 2),
      timestamp: DateTime(2026, 1, 1, 8, 0, 0),
      make: 'Google',
      model: 'Pixel 9 Pro',
    );
    final exif = img.decodeJpg(bytes)!.exif;
    expect(exif.gpsIfd.isEmpty, isTrue);
    expect(exif.imageIfd['Model']?.toString(), 'Pixel 9 Pro');
  });

  test('encodeJpgWithInfo matches the Position-based adapter', () {
    const timestamp = (year: 2026, month: 6, day: 11);
    final viaInfo = encodeJpgWithInfo(
      img.Image(width: 4, height: 4),
      JpegEncodeInfo(
        timestamp: DateTime(timestamp.year, timestamp.month, timestamp.day, 14, 30, 15),
        latitude: 37.422,
        longitude: -122.084,
        altitude: 12.5,
        heading: 90.0,
        gpsTimestamp: DateTime.utc(timestamp.year, timestamp.month, timestamp.day, 14, 30, 15),
        make: 'Google',
        model: 'Pixel 9 Pro',
      ),
    );
    final viaAdapter = encodeJpgWithMetadata(
      img.Image(width: 4, height: 4),
      timestamp: DateTime(timestamp.year, timestamp.month, timestamp.day, 14, 30, 15),
      position: fakePosition(),
      make: 'Google',
      model: 'Pixel 9 Pro',
    );

    final a = img.decodeJpg(viaInfo)!.exif;
    final b = img.decodeJpg(viaAdapter)!.exif;
    expect(a.imageIfd['Make']?.toString(), b.imageIfd['Make']?.toString());
    expect(a.imageIfd['Model']?.toString(), b.imageIfd['Model']?.toString());
    expect(a.imageIfd['DateTime']?.toString(), b.imageIfd['DateTime']?.toString());
    expect(a.gpsIfd['GPSLatitudeRef']?.toString(), b.gpsIfd['GPSLatitudeRef']?.toString());
    expect(a.gpsIfd['GPSLatitude']?.toString(), b.gpsIfd['GPSLatitude']?.toString());
    expect(a.gpsIfd['GPSLongitude']?.toString(), b.gpsIfd['GPSLongitude']?.toString());
    expect(a.gpsIfd['GPSAltitude']?.toDouble(), b.gpsIfd['GPSAltitude']?.toDouble());
    expect(a.gpsIfd['GPSImgDirection']?.toDouble(), b.gpsIfd['GPSImgDirection']?.toDouble());
    expect(a.gpsIfd[0x1d]?.toString(), b.gpsIfd[0x1d]?.toString());
  });
}
