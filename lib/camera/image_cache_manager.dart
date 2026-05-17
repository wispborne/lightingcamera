import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals.dart';

class ImageWithMetadata {
  final CameraImage image;
  final DateTime timestamp;
  final int sequenceNumber;
  final DeviceOrientation orientation;
  final CameraLensDirection lensDirection;

  ImageWithMetadata({
    required this.image,
    required this.timestamp,
    required this.sequenceNumber,
    required this.orientation,
    required this.lensDirection,
  });

  int get memoryUsage {
    int totalBytes = 0;
    for (final plane in image.planes) {
      totalBytes += plane.bytes.length;
    }
    return totalBytes;
  }
}

final imageCacheManager = ImageCacheManager();

class ImageCacheManager {
  final _cachedImages = listSignal<ImageWithMetadata>([]);
  final int _maxCacheSize = 100;
  int _sequenceCounter = 0;

  late final cacheSize = computed(() => _cachedImages.value.length);

  void addImage(
    CameraImage image,
    DeviceOrientation orientation,
    CameraLensDirection lensDirection,
  ) {
    final imageWithMetadata = ImageWithMetadata(
      image: image,
      timestamp: DateTime.now(),
      sequenceNumber: _sequenceCounter++,
      orientation: orientation,
      lensDirection: lensDirection,
    );

    _cachedImages.add(imageWithMetadata);

    while (_cachedImages.length > _maxCacheSize) {
      _cachedImages.removeAt(0);
    }
  }

  List<CameraImage> getCachedImages() {
    return _cachedImages.map((timestamped) => timestamped.image).toList();
  }

  List<ImageWithMetadata> getTimestampedImages() {
    return List.from(_cachedImages);
  }

  void clearCache() {
    _cachedImages.clear();
    _sequenceCounter = 0;
  }

  CameraImage? get latestImage =>
      _cachedImages.isNotEmpty ? _cachedImages.last.image : null;

  ImageWithMetadata? get latestTimestampedImage =>
      _cachedImages.isNotEmpty ? _cachedImages.last : null;

  int getCacheMemoryUsage() {
    return _cachedImages.fold(
      0,
      (total, timestamped) => total + timestamped.memoryUsage,
    );
  }

  double getCacheMemoryUsageMB() {
    return getCacheMemoryUsage() / (1024 * 1024);
  }

  double getCacheDurationSeconds() {
    if (_cachedImages.isEmpty) return 0.0;

    final oldestTimestamp = _cachedImages.first.timestamp;
    final newestTimestamp = _cachedImages.last.timestamp;

    return newestTimestamp.difference(oldestTimestamp).inMilliseconds / 1000.0;
  }

  double getAverageFPS() {
    if (_cachedImages.length < 2) return 0.0;

    final duration = getCacheDurationSeconds();
    return duration > 0 ? (_cachedImages.length - 1) / duration : 0.0;
  }

  DateTime? get oldestImageTimestamp =>
      _cachedImages.isNotEmpty ? _cachedImages.first.timestamp : null;

  DateTime? get newestImageTimestamp =>
      _cachedImages.isNotEmpty ? _cachedImages.last.timestamp : null;
}
