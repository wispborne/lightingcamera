import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// Wrapper class for CameraImage that includes timestamp and other metadata
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

  /// Get the memory usage of this image in bytes
  int get memoryUsage {
    int totalBytes = 0;
    for (final plane in image.planes) {
      totalBytes += plane.bytes.length;
    }
    return totalBytes;
  }
}

class ImageCacheManager {
  static final ImageCacheManager _instance = ImageCacheManager._internal();

  factory ImageCacheManager() => _instance;

  ImageCacheManager._internal();

  final List<ImageWithMetadata> _cachedImages = [];
  final int _maxCacheSize = 100;
  int _sequenceCounter = 0;

  /// Add a new image to the cache, removing oldest if necessary
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

    // Remove oldest images if we exceed the limit
    while (_cachedImages.length > _maxCacheSize) {
      _cachedImages.removeAt(0);
    }
  }

  /// Get a copy of all cached images (returns just the CameraImage objects for compatibility)
  List<CameraImage> getCachedImages() {
    return _cachedImages.map((timestamped) => timestamped.image).toList();
  }

  /// Get all timestamped images
  List<ImageWithMetadata> getTimestampedImages() {
    return List.from(_cachedImages);
  }

  /// Clear all cached images (call when returning from gallery)
  void clearCache() {
    _cachedImages.clear();
    _sequenceCounter = 0;
  }

  /// Get the number of cached images
  int get cacheSize => _cachedImages.length;

  /// Get the latest image for preview
  CameraImage? get latestImage =>
      _cachedImages.isNotEmpty ? _cachedImages.last.image : null;

  /// Get the latest timestamped image
  ImageWithMetadata? get latestTimestampedImage =>
      _cachedImages.isNotEmpty ? _cachedImages.last : null;

  /// Calculate the approximate memory usage of the cache in bytes
  int getCacheMemoryUsage() {
    return _cachedImages.fold(
      0,
      (total, timestamped) => total + timestamped.memoryUsage,
    );
  }

  /// Get cache memory usage in MB
  double getCacheMemoryUsageMB() {
    return getCacheMemoryUsage() / (1024 * 1024);
  }

  /// Get the duration of cached images in seconds
  double getCacheDurationSeconds() {
    if (_cachedImages.isEmpty) return 0.0;

    final oldestTimestamp = _cachedImages.first.timestamp;
    final newestTimestamp = _cachedImages.last.timestamp;

    return newestTimestamp.difference(oldestTimestamp).inMilliseconds / 1000.0;
  }

  /// Get the average FPS of cached images
  double getAverageFPS() {
    if (_cachedImages.length < 2) return 0.0;

    final duration = getCacheDurationSeconds();
    return duration > 0 ? (_cachedImages.length - 1) / duration : 0.0;
  }

  /// Get the oldest cached image timestamp
  DateTime? get oldestImageTimestamp =>
      _cachedImages.isNotEmpty ? _cachedImages.first.timestamp : null;

  /// Get the newest cached image timestamp
  DateTime? get newestImageTimestamp =>
      _cachedImages.isNotEmpty ? _cachedImages.last.timestamp : null;
}
