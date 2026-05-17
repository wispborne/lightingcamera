# Design: Migrate from Riverpod to Signals

## Current Riverpod Usage (3 touch points)

| File | Riverpod API Used |
|---|---|
| `lib/main.dart` | `ProviderScope` wrapper |
| `lib/camera/camera_page.dart` | `ConsumerStatefulWidget`, `ConsumerState`, `ref.read(imageCacheProvider)` ×3 |
| `lib/camera/gallery_page.dart` | `ConsumerStatefulWidget`, `ConsumerState`, `ref.read(imageCacheProvider)` ×2 |
| `lib/camera/image_cache_manager.dart` | `ChangeNotifierProvider`, `ChangeNotifier`, `notifyListeners()` |

## Approach

### 1. ImageCacheManager — Signal-backed singleton

Replace the `ChangeNotifier` base class with plain Dart. Expose reactive state via
signals so the UI can observe changes without manual `notifyListeners()`:

```dart
import 'package:signals/signals.dart';

final imageCacheManager = ImageCacheManager();

class ImageCacheManager {
  final _cachedImages = listSignal<ImageWithMetadata>([]);
  int _sequenceCounter = 0;

  // Derived/computed values become computed signals
  late final cacheSize = computed(() => _cachedImages.value.length);

  void addImage(...) {
    _cachedImages.value = [..._cachedImages.value, newImage];
    // No notifyListeners() needed — signals propagate automatically
  }

  void clearCache() {
    _cachedImages.value = [];
    _sequenceCounter = 0;
  }
  // ... rest of API stays the same
}
```

### 2. main.dart

Remove `ProviderScope`. The app widget becomes a plain `MaterialApp.router` — no
wrapper needed since `ImageCacheManager` is a top-level singleton accessed directly.

### 3. CameraPage / GalleryPage

- Revert to `StatefulWidget` / `State` (drop `Consumer*` variants)
- Replace `ref.read(imageCacheProvider)` with direct `imageCacheManager` access
- For any UI that needs to react to signal changes, use `Watch` widget from
  `signals_flutter` or the `SignalsMixin` on `State`

### 4. Dependencies

```yaml
# Remove
flutter_riverpod: ^3.3.1

# Add
signals: ^6.3.0
```

## Key Decisions

- **Singleton vs DI**: Using a top-level `final imageCacheManager` instance. The app
  has exactly one cache — DI adds complexity with no benefit here.
- **`listSignal` vs `signal`**: `listSignal` gives list-specific reactivity out of the
  box instead of wrapping `List` in a plain `signal`.
- **Minimal signal surface**: Only the properties that the UI reads reactively need to
  be signals. Internal-only fields stay as regular Dart fields.

## Files Changed

1. `pubspec.yaml` — swap dependency
2. `lib/camera/image_cache_manager.dart` — rewrite to signals
3. `lib/main.dart` — remove `ProviderScope`, remove riverpod import
4. `lib/camera/camera_page.dart` — `StatefulWidget`, direct access
5. `lib/camera/gallery_page.dart` — `StatefulWidget`, direct access
