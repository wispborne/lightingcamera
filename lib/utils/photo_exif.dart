import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;

import 'logging.dart';

/// Builds JPEG bytes for a saved frame, stamping common EXIF metadata — capture
/// time, the camera's make/model, and (when available) the GPS location — into
/// the file so the photo carries the same details a normal camera would write.
///
/// The frames we cache are raw camera data with no metadata of their own, so we
/// add it here at save time. Location is optional: when the user has geotagging
/// off, or hasn't granted location, we still write everything else.

/// The phone's manufacturer and model, looked up once and reused. Null until the
/// first [loadDeviceCameraInfo] call resolves it.
({String make, String model})? _deviceInfo;

/// Reads the device make/model for the EXIF Make/Model tags. Cached after the
/// first call; never throws — returns null if the lookup fails.
Future<({String make, String model})?> loadDeviceCameraInfo() async {
  if (_deviceInfo != null) return _deviceInfo;
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    _deviceInfo = (make: info.manufacturer, model: info.model);
  } catch (e) {
    Fimber.e('Device info lookup for EXIF failed: $e', ex: e);
  }
  return _deviceInfo;
}

/// Resolves the current location for geotagging a saved photo. Returns null when
/// location services are off, permission isn't granted, or the fix can't be
/// obtained — callers treat that as "save without GPS". Never throws.
///
/// Tries a fresh high-accuracy fix first, then falls back to the last known
/// position if that times out, so a brief GPS delay doesn't block the save.
Future<Position?> resolvePhotoLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (_) {
      return await Geolocator.getLastKnownPosition();
    }
  } catch (e) {
    Fimber.e('Photo location lookup for EXIF failed: $e', ex: e);
    return null;
  }
}

/// Encodes [image] to JPEG at [quality], first writing common EXIF tags onto it:
/// capture time, software, orientation, resolution, pixel dimensions, the
/// camera [make]/[model], and the GPS [position] when one is supplied.
Uint8List encodeJpgWithMetadata(
  img.Image image, {
  required DateTime timestamp,
  Position? position,
  String? make,
  String? model,
  int quality = 95,
}) {
  final exif = image.exif;
  final ifd0 = exif.imageIfd;

  if (make != null && make.isNotEmpty) ifd0['Make'] = make;
  if (model != null && model.isNotEmpty) ifd0['Model'] = model;
  ifd0['Software'] = 'Lightning Camera';
  // Frames are already rotated upright during conversion, so the stored
  // orientation is "normal".
  ifd0['Orientation'] = 1;
  ifd0['XResolution'] = [72, 1];
  ifd0['YResolution'] = [72, 1];
  ifd0['ResolutionUnit'] = 2; // inches
  ifd0['DateTime'] = _exifDateTime(timestamp);

  final exifIfd = exif.exifIfd;
  exifIfd['DateTimeOriginal'] = _exifDateTime(timestamp);
  exifIfd['DateTimeDigitized'] = _exifDateTime(timestamp);
  exifIfd['ColorSpace'] = 1; // sRGB
  exifIfd['PixelXDimension'] = image.width;
  exifIfd['PixelYDimension'] = image.height;

  if (position != null) {
    _writeGps(exif.gpsIfd, position);
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// Writes the GPS sub-IFD tags (latitude, longitude, altitude, heading, and the
/// fix's UTC date/time) for [p].
///
/// GPS tag IDs collide with unrelated tag IDs in the shared name→type table, so
/// the directory's type inference would guess wrong for a plain list. We sidestep
/// that by handing it fully-typed [img.IfdValue] objects, which it stores as-is.
void _writeGps(img.IfdDirectory gps, Position p) {
  final lat = p.latitude;
  final lng = p.longitude;

  gps['GPSVersionID'] =
      img.IfdByteValue.list(Uint8List.fromList([2, 3, 0, 0]));
  gps['GPSLatitudeRef'] = img.IfdValueAscii(lat >= 0 ? 'N' : 'S');
  gps['GPSLatitude'] = _degreesToDms(lat);
  gps['GPSLongitudeRef'] = img.IfdValueAscii(lng >= 0 ? 'E' : 'W');
  gps['GPSLongitude'] = _degreesToDms(lng);

  if (p.altitude.isFinite) {
    gps['GPSAltitudeRef'] = img.IfdByteValue(p.altitude < 0 ? 1 : 0);
    gps['GPSAltitude'] =
        img.IfdValueRational((p.altitude.abs() * 100).round(), 100);
  }

  // Compass heading the camera was pointing, when the fix carried one.
  if (p.heading.isFinite && p.heading >= 0) {
    gps['GPSImgDirectionRef'] = img.IfdValueAscii('T'); // true north
    gps['GPSImgDirection'] =
        img.IfdValueRational((p.heading * 100).round(), 100);
  }

  final utc = p.timestamp.toUtc();
  gps['GPSTimeStamp'] = _rationals([
    [utc.hour, 1],
    [utc.minute, 1],
    [utc.second, 1],
  ]);
  // Tag 0x1d (GPSDateStamp). Set by ID — the package labels it 'GPSDate', so
  // the standard name would be silently dropped.
  gps[0x1d] = img.IfdValueAscii(
    '${_pad(utc.year, 4)}:${_pad(utc.month, 2)}:${_pad(utc.day, 2)}',
  );
}

/// Encodes a signed decimal coordinate as the three EXIF rationals
/// (degrees, minutes, seconds). Always positive — the hemisphere is carried by
/// the separate ref tag.
img.IfdValueRational _degreesToDms(double coordinate) {
  var remainder = coordinate.abs();
  final degrees = remainder.floor();
  remainder = (remainder - degrees) * 60;
  final minutes = remainder.floor();
  remainder = (remainder - minutes) * 60; // seconds
  // Keep three decimals of seconds for ~3 cm precision.
  final secondsThousandths = (remainder * 1000).round();
  return _rationals([
    [degrees, 1],
    [minutes, 1],
    [secondsThousandths, 1000],
  ]);
}

/// Builds a multi-value rational from [numerator, denominator] pairs without
/// naming the package's (unexported) `Rational` type — we let inference pull it
/// from each single-value rational's `value` list.
img.IfdValueRational _rationals(List<List<int>> parts) =>
    img.IfdValueRational.list([
      for (final part in parts) img.IfdValueRational(part[0], part[1]).value.first,
    ]);

/// EXIF date/time format: `YYYY:MM:DD HH:MM:SS`, in the device's local time.
String _exifDateTime(DateTime t) =>
    '${_pad(t.year, 4)}:${_pad(t.month, 2)}:${_pad(t.day, 2)} '
    '${_pad(t.hour, 2)}:${_pad(t.minute, 2)}:${_pad(t.second, 2)}';

String _pad(int value, int width) => value.toString().padLeft(width, '0');
