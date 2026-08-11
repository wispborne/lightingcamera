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
import 'yuv_conversion_pool.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<ImageWithMetadata> images = [];
  // Reduced-resolution grid thumbnails, keyed by index into [images]. Generated
  // eagerly in the background when the gallery opens (see [_generateThumbnails])
  // so scrolling never waits on a conversion.
  final Map<int, ProcessedFrame> _thumbs = {};
  // Bumped whenever [images] is reindexed (deletion) or the page is torn down,
  // so background results that resolve against a stale layout are discarded.
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
      _generateThumbnails();
      lightningDetectionService.scan(images);
    });
  }

  double _currentPinchDistance() {
    final points = _pointers.values.toList();
    return (points[0] - points[1]).distance;
  }

  /// Queue every not-yet-converted frame for a background thumbnail. Tiles fill
  /// in progressively as the workers finish, in grid order.
  void _generateThumbnails() {
    final gen = _generation;
    for (int i = 0; i < images.length; i++) {
      if (!_thumbs.containsKey(i)) _generateThumbnail(i, gen);
    }
  }

  Future<void> _generateThumbnail(int index, int gen) async {
    if (index < 0 || index >= images.length) return;
    final frame = images[index];
    if (frame.image.format.group != ImageFormatGroup.yuv420) return;
    try {
      final result = await yuvConversionPool.convert(
        YuvConversionRequest.thumbnail(frame),
        priority: ConversionPriority.normal,
      );
      if (!mounted || gen != _generation) return;
      final processed = ProcessedFrame(result.bytes, result.width, result.height);
      // Decode to a texture now so the tile paints the instant it appears, then
      // drop the CPU-side bytes to keep a full buffer of thumbnails cheap.
      await processed.uiImage;
      processed.releaseBytes();
      if (!mounted || gen != _generation) {
        processed.dispose();
        return;
      }
      setState(() => _thumbs[index] = processed);
    } on YuvCancelledException {
      // Superseded by a deletion re-queue or the page closing — ignore.
    } catch (e) {
      Fimber.e('Thumbnail conversion failed for $index: $e', ex: e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Landscape screen height is scarce, so the app bar is made denser there.
    final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
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
          toolbarHeight: isLandscape ? 40 : null,
          // title: Text(_isSelecting ? '${_selected.length} selected' : 'Gallery (${images.length} images)'),
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
                                      isHit: lightningDetectionService.isHit(frame.sequenceNumber),
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
                                  (context, i) => _buildTile(
                                    i,
                                    isHit: lightningDetectionService.isHit(images[i].sequenceNumber),
                                  ),
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
    final newThumbs = <int, ProcessedFrame>{};
    int newIndex = 0;

    for (int oldIndex = 0; oldIndex < images.length; oldIndex++) {
      if (!indicesToRemove.contains(oldIndex)) {
        newImages.add(images[oldIndex]);
        final thumb = _thumbs[oldIndex];
        if (thumb != null) newThumbs[newIndex] = thumb;
        newIndex++;
      } else {
        _thumbs[oldIndex]?.dispose();
      }
    }

    // New layout: discard any in-flight results from the old indexing, then drop
    // queued thumbnail work so we can re-queue only what the survivors still need.
    _generation++;
    yuvConversionPool.cancelPending();

    setState(() {
      images = newImages;
      _thumbs.clear();
      _thumbs.addAll(newThumbs);
      _selected.clear();
      _selectionMode = false;
    });

    if (images.isNotEmpty) {
      _generateThumbnails();
    }
    // cancelPending() above also cancelled the running lightning scan's queued
    // work, which stops its loop with the counters frozen mid-scan. Restart it
    // over the survivors — frames already scanned keep their result and are
    // skipped, and with everything deleted this just settles the counters.
    lightningDetectionService.scan(images, keepResults: true);
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

  /// Encode and save [toSave] to the device gallery at full resolution,
  /// returning how many succeeded and failed. Conversion and JPEG encoding run
  /// in the background pool (a few in flight at once) so the gallery stays
  /// responsive. Assumes permission has already been granted.
  Future<(int saved, int failed)> _saveImages(List<ImageWithMetadata> toSave) async {
    // Resolve the location and camera details once, then stamp every frame with
    // them — the whole burst was shot from one spot within a few seconds.
    final position = settingsManager.geotagPhotos ? await resolvePhotoLocation() : null;
    final device = await loadDeviceCameraInfo();

    Future<bool> saveOne(ImageWithMetadata frame) async {
      try {
        if (frame.image.format.group != ImageFormatGroup.yuv420) return false;
        final info = JpegEncodeInfo(
          timestamp: frame.timestamp,
          latitude: position?.latitude,
          longitude: position?.longitude,
          altitude: position?.altitude,
          heading: position?.heading,
          gpsTimestamp: position?.timestamp,
          make: device?.make,
          model: device?.model,
        );
        final result = await yuvConversionPool.convert(
          YuvConversionRequest.jpeg(frame, info),
          priority: ConversionPriority.high,
        );
        await Gal.putImageBytes(
          result.bytes,
          name:
              'camera_image_${DateTime.now().millisecondsSinceEpoch}'
              '_${frame.sequenceNumber}.jpg',
        );
        return true;
      } catch (e) {
        Fimber.e('Error saving image: $e', ex: e);
        return false;
      }
    }

    int saved = 0;
    int failed = 0;
    // Window the work so both workers stay busy without flooding the queue.
    const concurrency = 3;
    for (int start = 0; start < toSave.length; start += concurrency) {
      final batch = toSave.skip(start).take(concurrency).toList();
      final results = await Future.wait(batch.map(saveOne));
      for (final ok in results) {
        if (ok) {
          saved++;
        } else {
          failed++;
        }
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

  void _showFullscreenImage(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            FullscreenImagePage(thumbs: _thumbs, rawImages: images, initialIndex: index),
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
  ///
  /// [isHit] is passed in rather than read from a per-tile `SignalBuilder`: the
  /// grid's outer `SignalBuilder` already subscribes to the confidence map and
  /// threshold (via `hitsByConfidence`), so it rebuilds every tile on any
  /// change anyway. A second subscription per tile just re-hashed the whole
  /// confidence map ~100× per scan tick for no benefit.
  Widget _buildTile(int imageIndex, {required bool isHit, double? confidence}) {
    final thumbImage = _thumbs[imageIndex]?.image;
    final selected = _selected.contains(imageIndex);

    Widget tileContent;
    if (thumbImage != null) {
      tileContent = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: RawImage(image: thumbImage, fit: BoxFit.cover),
      );
    } else {
      tileContent = const Center(child: Icon(Icons.image, color: Colors.white54, size: 30));
    }

    return GestureDetector(
      onTap: () {
        if (_selectionMode) {
          _toggleSelection(imageIndex);
        } else if (thumbImage != null) {
          _showFullscreenImage(imageIndex);
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
      child: Container(
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
    yuvConversionPool.cancelPending();
    for (final thumb in _thumbs.values) {
      thumb.dispose();
    }
    super.dispose();
  }
}

class FullscreenImagePage extends StatefulWidget {
  final Map<int, ProcessedFrame> thumbs;
  final List<ImageWithMetadata> rawImages;
  final int initialIndex;

  const FullscreenImagePage({
    super.key,
    required this.thumbs,
    required this.rawImages,
    required this.initialIndex,
  });

  @override
  State<FullscreenImagePage> createState() => _FullscreenImagePageState();
}

class _FullscreenImagePageState extends State<FullscreenImagePage> {
  late final PageController _pageController;
  late int _currentIndex;
  // Full-resolution frames, kept only for the pages near the one on screen so
  // browsing memory stays bounded.
  final Map<int, ProcessedFrame> _fullRes = {};
  final Set<int> _converting = {};

  /// How far from the current page a full-res frame may be before it's dropped.
  static const _keepRadius = 2;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    // Claim the volume keys while this viewer is on top. Without a listener
    // here, presses would fall through to the gallery's save-and-exit flow,
    // which would clear the cache and pop this viewer instead of the gallery.
    volumeKeyDispatcher.subscribe(_handleVolumeKey);
    _updateNeighborhood(widget.initialIndex);
  }

  /// Volume presses do nothing in the fullscreen viewer; subscribing just stops
  /// them reaching the gallery underneath.
  void _handleVolumeKey() {}

  @override
  void dispose() {
    volumeKeyDispatcher.unsubscribe(_handleVolumeKey);
    _pageController.dispose();
    for (final frame in _fullRes.values) {
      frame.dispose();
    }
    super.dispose();
  }

  /// Convert the current page and its immediate neighbors to full resolution,
  /// and drop full-res frames that have drifted more than two pages away.
  void _updateNeighborhood(int index) {
    _ensureFullRes(index);
    _ensureFullRes(index - 1);
    _ensureFullRes(index + 1);

    final stale = _fullRes.keys.where((k) => (k - index).abs() > _keepRadius).toList();
    for (final k in stale) {
      _fullRes.remove(k)?.dispose();
    }
  }

  void _ensureFullRes(int index) {
    if (index < 0 || index >= widget.rawImages.length) return;
    if (_fullRes.containsKey(index) || _converting.contains(index)) return;
    final frame = widget.rawImages[index];
    if (frame.image.format.group != ImageFormatGroup.yuv420) return;
    _converting.add(index);
    _convertFullRes(index, frame);
  }

  Future<void> _convertFullRes(int index, ImageWithMetadata frame) async {
    try {
      final result = await yuvConversionPool.convert(
        YuvConversionRequest.fullRes(frame),
        priority: ConversionPriority.high,
      );
      if (!mounted) return;
      // The user may have swiped far past this page while the conversion sat in
      // the queue. The prune that bounds memory only runs on a page change and
      // has already happened, so storing this frame now would keep it (and, in
      // a fast fling, dozens like it) alive until the next swipe. Drop it.
      if ((index - _currentIndex).abs() > _keepRadius) {
        _converting.remove(index);
        return;
      }
      final processed = ProcessedFrame(result.bytes, result.width, result.height);
      await processed.uiImage;
      processed.releaseBytes();
      if (!mounted || (index - _currentIndex).abs() > _keepRadius) {
        processed.dispose();
        _converting.remove(index);
        return;
      }
      setState(() {
        _fullRes[index] = processed;
        _converting.remove(index);
      });
    } on YuvCancelledException {
      _converting.remove(index);
    } catch (e) {
      Fimber.e('Error converting image $index in fullscreen: $e', ex: e);
      if (mounted) setState(() => _converting.remove(index));
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
          _updateNeighborhood(index);
        },
        itemBuilder: (context, index) {
          final fullImage = _fullRes[index]?.image;
          if (fullImage != null) {
            return Center(child: InteractiveViewer(child: RawImage(image: fullImage)));
          }
          // Show the grid thumbnail upscaled until the full-resolution frame
          // lands, so page flips are instant rather than a spinner.
          final thumbImage = widget.thumbs[index]?.image;
          if (thumbImage != null) {
            return Center(child: RawImage(image: thumbImage, fit: BoxFit.contain));
          }
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        },
      ),
    );
  }

  Future<void> _saveImage(BuildContext context, int index) async {
    final frame = widget.rawImages[index];
    if (frame.image.format.group != ImageFormatGroup.yuv420) return;

    try {
      PermissionStatus permission = await Permission.photos.status;
      if (!permission.isGranted) {
        permission = await Permission.photos.request();
      }

      if (permission.isGranted || permission.isLimited) {
        final position = settingsManager.geotagPhotos ? await resolvePhotoLocation() : null;
        final device = await loadDeviceCameraInfo();

        final result = await yuvConversionPool.convert(
          YuvConversionRequest.jpeg(
            frame,
            JpegEncodeInfo(
              timestamp: frame.timestamp,
              latitude: position?.latitude,
              longitude: position?.longitude,
              altitude: position?.altitude,
              heading: position?.heading,
              gpsTimestamp: position?.timestamp,
              make: device?.make,
              model: device?.model,
            ),
          ),
          priority: ConversionPriority.high,
        );

        await Gal.putImageBytes(result.bytes, name: 'camera_image_${DateTime.now().millisecondsSinceEpoch}.jpg');

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
