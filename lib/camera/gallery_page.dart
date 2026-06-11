import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:drag_select_grid_view/drag_select_grid_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img_lib;
import 'package:lightingcamera/camera/image_converter.dart';
import 'package:lightingcamera/settings/settings_manager.dart';
import 'package:lightingcamera/utils/logging.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final _gridController = DragSelectGridViewController();
  int _generation = 0;

  static const int _minCrossAxisCount = 2;
  static const int _maxCrossAxisCount = 8;
  static const int _portraitDefault = 3;
  static const int _landscapeDefault = 6;
  int? _userCrossAxisCount;
  final Map<int, Offset> _pointers = {};
  double? _initialPinchDistance;

  bool _isSavingAll = false;

  bool get _isSelecting => _gridController.value.isSelecting;
  Set<int> get _selectedIndexes => _gridController.value.selectedIndexes;

  @override
  void initState() {
    super.initState();
    _gridController.addListener(_onSelectionChanged);
    images = imageCacheManager.getTimestampedImages();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _convertImageBatch(0, _batchSize);
    });
  }

  void _onSelectionChanged() => setState(() {});

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

  Future<ProcessedImage?> _convertCameraImageToUIImage(
    ImageWithMetadata cameraImage,
  ) async {
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
          title: Text(
            _isSelecting
                ? '${_selectedIndexes.length} selected'
                : 'Gallery (${images.length} images)',
          ),
          leading: IconButton(
            icon: Icon(_isSelecting ? Icons.close : Icons.arrow_back),
            onPressed: _isSelecting ? _exitSelectionMode : _handleExit,
          ),
          actions: _isSelecting
              ? [
                  IconButton(
                    icon: const Icon(Icons.check_circle_outline),
                    tooltip: 'Keep selected',
                    onPressed: _selectedIndexes.isNotEmpty
                        ? _keepSelected
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete selected',
                    onPressed: _selectedIndexes.isNotEmpty
                        ? _deleteSelected
                        : null,
                  ),
                ]
              : [
                  IconButton(
                    icon: _isSavingAll
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_alt),
                    tooltip: 'Save all',
                    onPressed: (images.isNotEmpty && !_isSavingAll)
                        ? _saveAll
                        : null,
                  ),
                ],
          backgroundColor: _isSelecting
              ? Colors.deepPurple.shade900
              : Colors.black87,
          foregroundColor: Colors.white,
        ),
        backgroundColor: Colors.black,
        body: images.isEmpty
            ? const Center(
                child: Text(
                  'No images to display',
                  style: TextStyle(color: Colors.white),
                ),
              )
            : OrientationBuilder(
                builder: (context, orientation) {
                  final crossAxisCount = (_userCrossAxisCount ??
                      (orientation == Orientation.landscape
                          ? _landscapeDefault
                          : _portraitDefault))
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
                      if (_pointers.length == 2 &&
                          _initialPinchDistance != null) {
                        final dist = _currentPinchDistance();
                        final ratio = dist / _initialPinchDistance!;
                        if (ratio > 1.5 &&
                            crossAxisCount > _minCrossAxisCount) {
                          setState(() {
                            _userCrossAxisCount = crossAxisCount - 1;
                          });
                          _initialPinchDistance = dist;
                        } else if (ratio < 0.65 &&
                            crossAxisCount < _maxCrossAxisCount) {
                          setState(() {
                            _userCrossAxisCount = crossAxisCount + 1;
                          });
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
                    child: DragSelectGridView(
                      gridController: _gridController,
                      padding: const EdgeInsets.all(2),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 2,
                        crossAxisSpacing: 2,
                        childAspectRatio: 1,
                      ),
                      itemCount: images.length,
                      triggerSelectionOnTap: false,
                      impliesAppBarDismissal: false,
                      itemBuilder: (context, index, selected) {
                  if (index >=
                      _displayImages.length + _currentlyConverting.length) {
                    _convertImageBatch(index, _batchSize);
                  }

                  final displayImage = _displayImages[index];
                  final isConverting = _currentlyConverting.contains(index);

                  Widget tileContent;
                  if (displayImage != null) {
                    tileContent = ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: FutureBuilder<ui.Image>(
                        future: displayImage.displayImage,
                        builder: (context, asyncSnapshot) =>
                            !asyncSnapshot.hasData
                            ? const Center(child: CircularProgressIndicator())
                            : RawImage(
                                image: asyncSnapshot.requireData,
                                fit: BoxFit.cover,
                              ),
                      ),
                    );
                  } else if (isConverting) {
                    tileContent = const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    );
                  } else {
                    tileContent = const Center(
                      child: Icon(Icons.image, color: Colors.white54, size: 30),
                    );
                  }

                  return GestureDetector(
                    onTap: (!_isSelecting && displayImage != null)
                        ? () => _showFullscreenImage(
                              context, displayImage, index)
                        : null,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.grey[900],
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          tileContent,
                          if (_isSelecting && !selected)
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: Colors.black.withOpacity(0.4),
                              ),
                            ),
                          if (_isSelecting)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: selected
                                      ? Colors.deepPurple
                                      : Colors.black54,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                                child: selected
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.white,
                                        size: 16,
                                      )
                                    : null,
                              ),
                            ),
                        ],
                      ),
                    ),
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
    _gridController.clear();
  }

  void _deleteSelected() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete selected?'),
          content: Text(
            'Delete ${_selectedIndexes.length} image${_selectedIndexes.length == 1 ? '' : 's'}? '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _applyDeletion(Set<int>.from(_selectedIndexes));
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _keepSelected() {
    final toRemoveCount = images.length - _selectedIndexes.length;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Keep selected?'),
          content: Text(
            'Keep ${_selectedIndexes.length} image${_selectedIndexes.length == 1 ? '' : 's'} '
            'and delete the remaining $toRemoveCount?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                final allIndices = List.generate(
                  images.length,
                  (i) => i,
                ).toSet();
                _applyDeletion(allIndices.difference(_selectedIndexes));
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
    _gridController.clear();

    setState(() {
      images = newImages;
      _displayImages.clear();
      _displayImages.addAll(newDisplayImages);
      _currentlyConverting.clear();
    });

    if (images.isNotEmpty) {
      _convertImageBatch(0, _batchSize);
    }
  }

  Future<void> _saveAll() async {
    PermissionStatus permission = await Permission.photos.status;
    if (!permission.isGranted) {
      permission = await Permission.photos.request();
    }

    if (!(permission.isGranted || permission.isLimited)) {
      if (!mounted) return;
      if (permission.isPermanentlyDenied) {
        _showPermissionDialog(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Storage permission is required to save images'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() => _isSavingAll = true);

    int saved = 0;
    int failed = 0;

    // Snapshot the list so the indices stay valid even if a conversion frees a
    // slot in the middle of saving.
    final toSave = List<ImageWithMetadata>.from(images);

    for (int i = 0; i < toSave.length; i++) {
      try {
        // Reuse an already-converted frame when we have one, otherwise convert.
        final image =
            _displayImages[i] ?? await _convertCameraImageToUIImage(toSave[i]);
        if (image == null) {
          failed++;
          continue;
        }

        final bytes = Uint8List.fromList(
          img_lib.encodeJpg(image.image, quality: 95),
        );
        await Gal.putImageBytes(
          bytes,
          name:
              'camera_image_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
        );
        saved++;
      } catch (e) {
        Fimber.e('Error saving image during Save All: $e', ex: e);
        failed++;
      }
    }

    if (!mounted) return;
    setState(() => _isSavingAll = false);

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
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
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
                  const Text(
                    'Unsaved images will be lost. Are you sure you want to return to camera?',
                  ),
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () => setDialogState(
                      () => neverShowAgain = !neverShowAgain,
                    ),
                    child: Row(
                      children: [
                        Checkbox(
                          value: neverShowAgain,
                          onChanged: (value) => setDialogState(
                            () => neverShowAgain = value ?? false,
                          ),
                        ),
                        const Expanded(
                          child: Text('Never show this again'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Stay'),
                ),
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

  void _showFullscreenImage(
    BuildContext context,
    ProcessedImage timestampedImage,
    int index,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => FullscreenImagePage(
          displayImages: _displayImages,
          rawImages: images,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _gridController.removeListener(_onSelectionChanged);
    _gridController.dispose();
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
      if (i >= 0 &&
          i < widget.rawImages.length &&
          _getImage(i) == null &&
          !_converting.contains(i)) {
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
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () => _saveImage(context, _currentIndex),
          ),
        ],
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
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
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
        final bytes = Uint8List.fromList(
          img_lib.encodeJpg(image.image, quality: 95),
        );

        await Gal.putImageBytes(
          bytes,
          name: 'camera_image_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image saved to gallery successfully!'),
              backgroundColor: Colors.green,
            ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving image: $e'),
            backgroundColor: Colors.red,
          ),
        );
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
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
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
