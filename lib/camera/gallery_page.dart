import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:lightingcamera/camera/image_converter.dart';
import 'package:lightingcamera/camera/lightning_detection_service.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:lightingcamera/utils/photo_exif.dart';
import 'package:lightingcamera/utils/volume_key_dispatcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:signals/signals_flutter.dart';

import 'image_cache_manager.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<ImageWithMetadata> images = [];
  final Map<int, ProcessedImage> _displayImages = {};
  final Set<int> _currentlyConverting = {};
  final int _batchSize = 3;
  int _generation = 0;

  // Multi-select state. Indexes here point into [images]. Long-press a tile to
  // enter selection mode; tapping then toggles. Replaces the old drag-select
  // grid, which couldn't be split into labelled sections.
  final Set<int> _selected = {};
  bool _selectionMode = false;

  static const int _minCrossAxisCount = 2;
  static const int _maxCrossAxisCount = 8;
  static const int _portraitDefault = 3;
  static const int _landscapeDefault = 6;
  final Map<int, Offset> _pointers = {};
  double? _initialPinchDistance;

  // One busy flag covers both "Save all" and "Save lightning" so the two can
  // never run at once.
  bool _isSaving = false;

  // Whether the in-app sensitivity slider strip is showing under the app bar.
  bool _showSensitivity = false;

  // Volume save-and-exit flow state. `_volumeDialogOpen` is true while the
  // first-press confirmation dialog is up; `_volumeExiting` guards the
  // save-and-pop sequence so a stray press during it is ignored.
  bool _volumeDialogOpen = false;
  bool _volumeExiting = false;

  bool get _isSelecting => _selectionMode;

  @override
  void initState() {
    super.initState();
    images = imageCacheManager.getTimestampedImages();
    volumeKeyDispatcher.subscribe(_handleVolumeKey);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _convertImageBatch(0, _batchSize);
      lightningDetectionService.scan(images);
    });
  }

  double _currentPinchDistance() {
    final points = _pointers.values.toList();
    return (points[0] - points[1]).distance;
  }

  Future<void> _convertImageBatch(int start, int count) async {
    final end = (start + count).clamp(0, images.length);

    for (int i = start; i < end; i++) {
      if (_displayImages.containsKey(i) || _currentlyConverting.contains(i)) {
        continue;
      }

      _currentlyConverting.add(i);
      _convertSingleImage(i);
    }
  }

  Future<void> _convertSingleImage(int index) async {
    final gen = _generation;
    try {
      final timestampedImage = images[index];
      final displayImage = await _convertCameraImageToUIImage(timestampedImage);

      if (mounted && displayImage != null && _generation == gen) {
        setState(() {
          _displayImages[index] = displayImage;
          _currentlyConverting.remove(index);
        });
      }
    } catch (e) {
      Fimber.e('Error converting image $index: $e', ex: e);
      if (mounted && _generation == gen) {
        _currentlyConverting.remove(index);
      }
    }
  }

  Future<ProcessedImage?> _convertCameraImageToUIImage(ImageWithMetadata cameraImage) async {
    try {
      if (cameraImage.image.format.group == ImageFormatGroup.yuv420) {
        return ImageConverter.processImage(cameraImage);
      }
      return null;
    } catch (e) {
      Fimber.e('Error in _convertCameraImageToUIImage: $e', ex: e);
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          if (_isSelecting) {
            _exitSelectionMode();
          } else {
            _handleExit();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isSelecting ? '${_selected.length} selected' : 'Gallery (${images.length} images)'),
          leading: IconButton(
            icon: Icon(_isSelecting ? Icons.close : Icons.arrow_back),
            onPressed: _isSelecting ? _exitSelectionMode : _handleExit,
          ),
          actions: _isSelecting
              ? [
                  IconButton(
                    icon: const Icon(Icons.check_circle_outline),
                    tooltip: 'Keep selected',
                    onPressed: _selected.isNotEmpty ? _keepSelected : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete selected',
                    onPressed: _selected.isNotEmpty ? _deleteSelected : null,
                  ),
                ]
              : [
                  IconButton(
                    icon: Icon(Icons.tune, color: _showSensitivity ? Colors.amber : Colors.white),
                    tooltip: 'Lightning sensitivity',
                    onPressed: () => setState(() => _showSensitivity = !_showSensitivity),
                  ),
                  SignalBuilder(
                    builder: (context) {
                      final count = lightningDetectionService.hitsByConfidence(images).length;
                      return IconButton(
                        icon: Badge.count(count: count, isLabelVisible: count > 0, child: const Icon(Icons.bolt)),
                        tooltip: 'Save lightning ($count)',
                        onPressed: (count > 0 && !_isSaving) ? _saveLightning : null,
                      );
                    },
                  ),
                  PopupMenuButton<String>(
                    icon: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.more_vert),
                    tooltip: 'More',
                    enabled: !_isSaving,
                    onSelected: (value) {
                      if (value == 'save_all') _saveAll();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        value: 'save_all',
                        enabled: images.isNotEmpty && !_isSaving,
                        child: const Row(children: [Icon(Icons.save_alt), SizedBox(width: 12), Text('Save all')]),
                      ),
                    ],
                  ),
                ],
          // Black-tinted bars keep the gallery reading as a photo viewer; the
          // selecting state picks up the theme accent instead of the old seed.
          backgroundColor: _isSelecting ? Theme.of(context).colorScheme.primaryContainer : Colors.black87,
          foregroundColor: Colors.white,
          bottom: _isSelecting ? null : _buildAppBarBottom(),
        ),
        backgroundColor: Colors.black,
        body: images.isEmpty
            ? const Center(
                child: Text('No images to display', style: TextStyle(color: Colors.white)),
              )
            : OrientationBuilder(
                builder: (context, orientation) {
                  final crossAxisCount =
                      (settingsManager.galleryCrossAxisCount ??
                              (orientation == Orientation.landscape ? _landscapeDefault : _portraitDefault))
                          .clamp(_minCrossAxisCount, _maxCrossAxisCount);

                  return Listener(
                    onPointerDown: (e) {
                      _pointers[e.pointer] = e.localPosition;
                      if (_pointers.length == 2) {
                        _initialPinchDistance = _currentPinchDistance();
                      }
                    },
                    onPointerMove: (e) {
                      _pointers[e.pointer] = e.localPosition;
                      if (_pointers.length == 2 && _initialPinchDistance != null) {
                        final dist = _currentPinchDistance();
                        final ratio = dist / _initialPinchDistance!;
                        if (ratio > 1.5 && crossAxisCount > _minCrossAxisCount) {
                          settingsManager.setGalleryCrossAxisCount(crossAxisCount - 1);
                          setState(() {});
                          _initialPinchDistance = dist;
                        } else if (ratio < 0.65 && crossAxisCount < _maxCrossAxisCount) {
                          settingsManager.setGalleryCrossAxisCount(crossAxisCount + 1);
                          setState(() {});
                          _initialPinchDistance = dist;
                        }
                      }
                    },
                    onPointerUp: (e) {
                      _pointers.remove(e.pointer);
                      if (_pointers.length < 2) {
                        _initialPinchDistance = null;
                      }
                    },
                    onPointerCancel: (e) {
                      _pointers.remove(e.pointer);
                      if (_pointers.length < 2) {
                        _initialPinchDistance = null;
                      }
                    },
                    child: SignalBuilder(
                      builder: (context) {
                        // Two labelled sections in one gallery: the lightning
                        // hits pulled to the top (most confident first) for quick
                        // access, then every photo under "All Photos" — the hits
                        // stay in that full list too, highlighted, so nothing is
                        // hidden away.
                        final hits = lightningDetectionService.hitsByConfidence(images);
                        final indexBySeq = {for (int i = 0; i < images.length; i++) images[i].sequenceNumber: i};
                        final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                          childAspectRatio: 1,
                        );

                        return CustomScrollView(
                          slivers: [
                            if (hits.isNotEmpty) ...[
                              SliverToBoxAdapter(child: _sectionHeader('Lightning', hits.length, lightning: true)),
                              SliverPadding(
                                padding: const EdgeInsets.all(2),
                                sliver: SliverGrid(
                                  gridDelegate: gridDelegate,
                                  delegate: SliverChildBuilderDelegate((context, i) {
                                    final frame = hits[i];
                                    return _buildTile(
                                      indexBySeq[frame.sequenceNumber]!,
                                      confidence: lightningDetectionService.confidenceFor(frame.sequenceNumber) ?? 0,
                                    );
                                  }, childCount: hits.length),
                                ),
                              ),
                            ],
                            SliverToBoxAdapter(child: _sectionHeader('All Photos', images.length)),
                            SliverPadding(
                              padding: const EdgeInsets.all(2),
                              sliver: SliverGrid(
                                gridDelegate: gridDelegate,
                                delegate: SliverChildBuilderDelegate(
                                  (context, i) => _buildTile(i),
                                  childCount: images.length,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }

  void _exitSelectionMode() {
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
  }

  /// Toggle one tile's selection. Leaving the last selection drops out of
  /// selection mode so the app bar returns to its normal actions.
  void _toggleSelection(int index) {
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _deleteSelected() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete selected?'),
          content: Text(
            'Delete ${_selected.length} image${_selected.length == 1 ? '' : 's'}? '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _applyDeletion(Set<int>.from(_selected));
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _keepSelected() {
    final toRemoveCount = images.length - _selected.length;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Keep selected?'),
          content: Text(
            'Keep ${_selected.length} image${_selected.length == 1 ? '' : 's'} '
            'and delete the remaining $toRemoveCount?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                final allIndices = List.generate(images.length, (i) => i).toSet();
                _applyDeletion(allIndices.difference(_selected));
              },
              child: const Text('Keep'),
            ),
          ],
        );
      },
    );
  }

  void _applyDeletion(Set<int> indicesToRemove) {
    if (indicesToRemove.isEmpty) return;

    imageCacheManager.removeAtIndices(indicesToRemove);

    final newImages = <ImageWithMetadata>[];
    final newDisplayImages = <int, ProcessedImage>{};
    int newIndex = 0;

    for (int oldIndex = 0; oldIndex < images.length; oldIndex++) {
      if (!indicesToRemove.contains(oldIndex)) {
        newImages.add(images[oldIndex]);
        if (_displayImages.containsKey(oldIndex)) {
          newDisplayImages[newIndex] = _displayImages[oldIndex]!;
        }
        newIndex++;
      } else {
        _displayImages[oldIndex]?.dispose();
      }
    }

    _generation++;

    setState(() {
      images = newImages;
      _displayImages.clear();
      _displayImages.addAll(newDisplayImages);
      _currentlyConverting.clear();
      _selected.clear();
      _selectionMode = false;
    });

    if (images.isNotEmpty) {
      _convertImageBatch(0, _batchSize);
    }
  }

  Future<void> _saveAll() async {
    final count = images.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Save all images?'),
          content: Text('Save $count image${count == 1 ? '' : 's'} to your device gallery?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Save all')),
          ],
        );
      },
    );
    if (confirmed != true) return;
    if (!mounted) return;
    if (!await _ensurePhotoPermission()) return;
    setState(() => _isSaving = true);
    final (saved, failed) = await _saveImages(List<ImageWithMetadata>.from(images));
    if (!mounted) return;
    setState(() => _isSaving = false);
    _showSaveResult(saved, failed);
  }

  Future<void> _saveLightning() async {
    if (!await _ensurePhotoPermission()) return;
    setState(() => _isSaving = true);
    final (saved, failed) = await _saveImages(lightningDetectionService.hitsByConfidence(images));
    if (!mounted) return;
    setState(() => _isSaving = false);
    _showSaveResult(saved, failed);
  }

  /// Make sure we can write to the gallery, surfacing the right prompt if not.
  /// Returns true when saving may proceed.
  Future<bool> _ensurePhotoPermission() async {
    PermissionStatus permission = await Permission.photos.status;
    if (!permission.isGranted) {
      permission = await Permission.photos.request();
    }
    if (permission.isGranted || permission.isLimited) return true;

    if (!mounted) return false;
    if (permission.isPermanentlyDenied) {
      _showPermissionDialog(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Storage permission is required to save images'), backgroundColor: Colors.orange),
      );
    }
    return false;
  }

  /// Encode and save [toSave] to the device gallery, returning how many
  /// succeeded and failed. Assumes permission has already been granted.
  Future<(int saved, int failed)> _saveImages(List<ImageWithMetadata> toSave) async {
    // Resolve the location and camera details once, then stamp every frame with
    // them — the whole burst was shot from one spot within a few seconds.
    final position = settingsManager.geotagPhotos ? await resolvePhotoLocation() : null;
    final device = await loadDeviceCameraInfo();

    // Reuse already-converted frames, keyed by sequence number so a filtered
    // subset (e.g. just the lightning hits) still lines up with the cache.
    final converted = <int, ProcessedImage>{};
    for (final entry in _displayImages.entries) {
      if (entry.key < images.length) {
        converted[images[entry.key].sequenceNumber] = entry.value;
      }
    }

    int saved = 0;
    int failed = 0;

    for (final frame in toSave) {
      try {
        final image = converted[frame.sequenceNumber] ?? await _convertCameraImageToUIImage(frame);
        if (image == null) {
          failed++;
          continue;
        }

        final bytes = encodeJpgWithMetadata(
          image.image,
          timestamp: frame.timestamp,
          position: position,
          make: device?.make,
          model: device?.model,
        );
        await Gal.putImageBytes(
          bytes,
          name:
              'camera_image_${DateTime.now().millisecondsSinceEpoch}'
              '_${frame.sequenceNumber}.jpg',
        );
        saved++;
      } catch (e) {
        Fimber.e('Error saving image: $e', ex: e);
        failed++;
      }
    }

    return (saved, failed);
  }

  void _showSaveResult(int saved, int failed) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Saved $saved image${saved == 1 ? '' : 's'} to gallery'
              : 'Saved $saved, failed to save $failed',
        ),
        backgroundColor: failed == 0 ? Colors.green : Colors.orange,
      ),
    );
  }

  void _showPermissionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Storage Permission Required'),
          content: const Text(
            'This app needs storage permission to save images to your gallery. Please enable it in the app settings.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }

  void _handleExit() {
    // The user opted out of the confirmation earlier — leave straight away.
    if (settingsManager.skipGalleryExitWarning) {
      _returnToCamera();
      return;
    }
    _showExitDialog();
  }

  /// Close the dialog (if any) first, then pop the gallery so the camera page
  /// gets a single, clean didPopNext. Navigating home via goNamed() while a
  /// dialog was still on the stack made go_router rebuild its page list and fire
  /// a spurious "covered" event that tore the camera back down right after it
  /// reopened.
  void _returnToCamera() {
    imageCacheManager.clearCache();
    lightningDetectionService.reset();
    if (mounted) context.pop();
  }

  void _showExitDialog() {
    bool neverShowAgain = false;
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Warning'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Unsaved images will be lost. Are you sure you want to return to camera?'),
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () => setDialogState(() => neverShowAgain = !neverShowAgain),
                    child: Row(
                      children: [
                        Checkbox(
                          value: neverShowAgain,
                          onChanged: (value) => setDialogState(() => neverShowAgain = value ?? false),
                        ),
                        const Expanded(child: Text('Never show this again')),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Stay')),
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    if (neverShowAgain) {
                      settingsManager.setSkipGalleryExitWarning(true);
                    }
                    _returnToCamera();
                  },
                  child: const Text('Return to camera'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showFullscreenImage(BuildContext context, ProcessedImage timestampedImage, int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            FullscreenImagePage(displayImages: _displayImages, rawImages: images, initialIndex: index),
      ),
    );
  }

  /// The strip under the app bar: the scan progress line, a one-line status
  /// describing what detection is doing, and — when toggled on — the in-place
  /// sensitivity slider. They share this one band so the page keeps to a single
  /// overlay level.
  PreferredSizeWidget _buildAppBarBottom() {
    return PreferredSize(
      preferredSize: Size.fromHeight(_showSensitivity ? 90 : 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SignalBuilder(
            builder: (context) {
              if (!lightningDetectionService.isScanning.value) {
                return const SizedBox(height: 3);
              }
              final scanned = lightningDetectionService.scannedCount.value;
              final total = lightningDetectionService.totalCount.value;
              return LinearProgressIndicator(
                value: total > 0 ? scanned / total : null,
                minHeight: 3,
                backgroundColor: Colors.black,
                color: Colors.amber,
              );
            },
          ),
          SignalBuilder(
            builder: (context) {
              final scanning = lightningDetectionService.isScanning.value;
              final scanned = lightningDetectionService.scannedCount.value;
              final total = lightningDetectionService.totalCount.value;
              final count = lightningDetectionService.hitsByConfidence(images).length;

              String label;
              if (scanning) {
                label = 'Scanning for lightning… $scanned/$total';
              } else if (total == 0) {
                // Scan hasn't run yet (or nothing to scan) — say nothing.
                label = '';
              } else if (count == 0) {
                label = 'No lightning found. Adjust sensitivity if needed.';
              } else {
                label = '$count lightning photo${count == 1 ? '' : 's'} found';
              }

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              );
            },
          ),
          if (_showSensitivity)
            SignalBuilder(
              builder: (context) {
                final threshold = settingsManager.lightningThresholdSignal.value;
                return Column(
                  mainAxisSize: .min,
                  crossAxisAlignment: .center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 8, top: 2),
                      child: Text(
                        'Lightning detection sensitivity. Lower finds more.',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 8),
                        const Icon(Icons.bolt, color: Colors.amber, size: 18),
                        Expanded(
                          child: Slider(
                            value: threshold,
                            min: SettingsManager.minLightningThreshold,
                            max: SettingsManager.maxLightningThreshold,
                            divisions: 16,
                            label: '${(threshold * 100).round()}%',
                            onChanged: settingsManager.setLightningThreshold,
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text('${(threshold * 100).round()}%', style: const TextStyle(color: Colors.white)),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  /// A group label above one of the gallery sections, e.g. "Lightning (3)" or
  /// "All Photos (42)". The lightning label carries the amber bolt.
  Widget _sectionHeader(String label, int count, {bool lightning = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Row(
        children: [
          if (lightning) ...[const Icon(Icons.bolt, color: Colors.amber, size: 18), const SizedBox(width: 4)],
          Text('$label ($count)', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white)),
        ],
      ),
    );
  }

  /// One gallery tile for the frame at [imageIndex] in [images]. Used by both
  /// the Lightning and All Photos sections. Pass [confidence] to show the
  /// detection badge in the corner (lightning section only).
  Widget _buildTile(int imageIndex, {double? confidence}) {
    if (_displayImages[imageIndex] == null && !_currentlyConverting.contains(imageIndex)) {
      _convertImageBatch(imageIndex, _batchSize);
    }

    final displayImage = _displayImages[imageIndex];
    final isConverting = _currentlyConverting.contains(imageIndex);
    final selected = _selected.contains(imageIndex);

    Widget tileContent;
    if (displayImage != null) {
      tileContent = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: FutureBuilder<ui.Image>(
          future: displayImage.displayImage,
          builder: (context, asyncSnapshot) => !asyncSnapshot.hasData
              ? const Center(child: CircularProgressIndicator())
              : RawImage(image: asyncSnapshot.requireData, fit: BoxFit.cover),
        ),
      );
    } else if (isConverting) {
      tileContent = const Center(
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
      );
    } else {
      tileContent = const Center(child: Icon(Icons.image, color: Colors.white54, size: 30));
    }

    return GestureDetector(
      onTap: () {
        if (_selectionMode) {
          _toggleSelection(imageIndex);
        } else if (displayImage != null) {
          _showFullscreenImage(context, displayImage, imageIndex);
        }
      },
      onLongPress: () {
        if (!_selectionMode) {
          setState(() {
            _selectionMode = true;
            _selected.add(imageIndex);
          });
        } else {
          _toggleSelection(imageIndex);
        }
      },
      child: SignalBuilder(
        builder: (context) {
          final isHit = lightningDetectionService.isHit(images[imageIndex].sequenceNumber);
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: Colors.grey[900],
              border: isHit ? Border.all(color: Colors.amber, width: 2) : null,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                tileContent,
                if (isHit) const Positioned(top: 4, left: 4, child: Icon(Icons.bolt, color: Colors.amber, size: 18)),
                if (confidence != null)
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                      child: Text(
                        '${(confidence * 100).round()}%',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                if (_selectionMode && !selected)
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: Colors.black.withOpacity(0.4),
                    ),
                  ),
                if (_selectionMode)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? Theme.of(context).colorScheme.primary : Colors.black54,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: selected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A volume press while the gallery is on top drives the save-and-exit flow:
  /// the first press opens the confirmation dialog, the second confirms it.
  void _handleVolumeKey() {
    if (!mounted || _volumeExiting) return;
    if (_volumeDialogOpen) {
      _confirmVolumeSaveExit();
    } else {
      _showVolumeSaveExitDialog();
    }
  }

  void _showVolumeSaveExitDialog() {
    _volumeDialogOpen = true;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return SignalBuilder(
          builder: (context) {
            final scanning = lightningDetectionService.isScanning.value;
            final scanned = lightningDetectionService.scannedCount.value;
            final total = lightningDetectionService.totalCount.value;
            final count = lightningDetectionService.hitsByConfidence(images).length;

            // Once the scan is done with nothing found, there's nothing to
            // save — frame the whole dialog as a plain exit, not a save.
            final nothingToSave = !scanning && count == 0;

            final String message;
            if (scanning) {
              message =
                  'Still scanning ($scanned/$total) — $count with lightning so '
                  'far. Saving will wait for the scan to finish, then return to '
                  'the camera. Press a volume button again to confirm.';
            } else if (count == 0) {
              message = 'No lightning detected. Return to the camera without saving?';
            } else {
              message =
                  'Save $count lightning image${count == 1 ? '' : 's'} to your '
                  'device, then return to the camera. Press a volume button '
                  'again to confirm.';
            }

            return AlertDialog(
              title: Text(nothingToSave ? 'Return to camera?' : 'Save lightning & exit?'),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () {
                    _volumeDialogOpen = false;
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Cancel'),
                ),
                TextButton(onPressed: _confirmVolumeSaveExit, child: Text(nothingToSave ? 'Exit' : 'Save & exit')),
              ],
            );
          },
        );
      },
    ).then((_) {
      // However the dialog closed (tap-outside, back, Cancel), re-arm so the
      // next press starts the flow fresh.
      _volumeDialogOpen = false;
    });
  }

  Future<void> _confirmVolumeSaveExit() async {
    if (_volumeExiting) return;
    _volumeExiting = true;

    // Close the confirmation dialog if it's still up.
    if (_volumeDialogOpen) {
      _volumeDialogOpen = false;
      if (mounted) Navigator.of(context).pop();
    }

    // If anything might be saved, get permission up front so a denial aborts
    // the exit cleanly rather than after the wait.
    final mightSave =
        lightningDetectionService.isScanning.value || lightningDetectionService.hitsByConfidence(images).isNotEmpty;
    if (mightSave) {
      if (!await _ensurePhotoPermission()) {
        _volumeExiting = false;
        return;
      }
    }

    // Block on the scan finishing so no late-flagged frame is missed.
    if (mounted && lightningDetectionService.isScanning.value) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 16),
              Expanded(child: Text('Finishing scan…')),
            ],
          ),
        ),
      );
      await lightningDetectionService.whenScanComplete();
      if (mounted) Navigator.of(context).pop();
    }

    final hits = lightningDetectionService.hitsByConfidence(images);
    if (hits.isNotEmpty) {
      await _saveImages(hits);
    }

    _returnToCamera();
  }

  @override
  void dispose() {
    volumeKeyDispatcher.unsubscribe(_handleVolumeKey);
    lightningDetectionService.reset();
    for (final image in _displayImages.values) {
      image.dispose();
    }
    super.dispose();
  }
}

class FullscreenImagePage extends StatefulWidget {
  final Map<int, ProcessedImage> displayImages;
  final List<ImageWithMetadata> rawImages;
  final int initialIndex;

  const FullscreenImagePage({
    super.key,
    required this.displayImages,
    required this.rawImages,
    required this.initialIndex,
  });

  @override
  State<FullscreenImagePage> createState() => _FullscreenImagePageState();
}

class _FullscreenImagePageState extends State<FullscreenImagePage> {
  late final PageController _pageController;
  late int _currentIndex;
  final Map<int, ProcessedImage> _localConverted = {};
  final Set<int> _converting = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _ensureAdjacentConverted(widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  ProcessedImage? _getImage(int index) {
    return widget.displayImages[index] ?? _localConverted[index];
  }

  void _ensureAdjacentConverted(int index) {
    for (final i in [index - 1, index + 1]) {
      if (i >= 0 && i < widget.rawImages.length && _getImage(i) == null && !_converting.contains(i)) {
        _convertImage(i);
      }
    }
  }

  Future<void> _convertImage(int index) async {
    _converting.add(index);
    try {
      final raw = widget.rawImages[index];
      if (raw.image.format.group == ImageFormatGroup.yuv420) {
        final result = await ImageConverter.processImage(raw);
        if (mounted && result != null) {
          setState(() {
            _localConverted[index] = result;
            _converting.remove(index);
          });
        }
      }
    } catch (e) {
      Fimber.e('Error converting image $index in fullscreen: $e', ex: e);
      if (mounted) {
        setState(() => _converting.remove(index));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_currentIndex + 1} / ${widget.rawImages.length}',
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
        centerTitle: true,
        actions: [IconButton(icon: const Icon(Icons.save), onPressed: () => _saveImage(context, _currentIndex))],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.rawImages.length,
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
          _ensureAdjacentConverted(index);
        },
        itemBuilder: (context, index) {
          final image = _getImage(index);
          if (image == null) {
            if (!_converting.contains(index)) {
              _convertImage(index);
            }
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
          return Center(
            child: InteractiveViewer(
              child: FutureBuilder<ui.Image>(
                future: image.displayImage,
                builder: (context, asyncSnapshot) => !asyncSnapshot.hasData
                    ? const Center(child: CircularProgressIndicator())
                    : RawImage(image: asyncSnapshot.requireData),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _saveImage(BuildContext context, int index) async {
    final image = _getImage(index);
    if (image == null) return;

    try {
      PermissionStatus permission = await Permission.photos.status;
      if (!permission.isGranted) {
        permission = await Permission.photos.request();
      }

      if (permission.isGranted || permission.isLimited) {
        final position = settingsManager.geotagPhotos ? await resolvePhotoLocation() : null;
        final device = await loadDeviceCameraInfo();

        final bytes = encodeJpgWithMetadata(
          image.image,
          timestamp: widget.rawImages[index].timestamp,
          position: position,
          make: device?.make,
          model: device?.model,
        );

        await Gal.putImageBytes(bytes, name: 'camera_image_${DateTime.now().millisecondsSinceEpoch}.jpg');

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image saved to gallery successfully!'), backgroundColor: Colors.green),
          );
        }
      } else if (permission.isPermanentlyDenied) {
        if (context.mounted) {
          _showPermissionDialog(context);
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Storage permission is required to save images'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving image: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _showPermissionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Storage Permission Required'),
          content: const Text(
            'This app needs storage permission to save images to your gallery. Please enable it in the app settings.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }
}
