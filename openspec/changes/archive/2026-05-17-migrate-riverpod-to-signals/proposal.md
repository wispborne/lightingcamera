# Migrate from Riverpod to Signals

## Problem

The app uses `flutter_riverpod` (^3.3.1) for state management, but the actual usage
is trivial — a single `ChangeNotifierProvider` wrapping `ImageCacheManager`. Riverpod
adds significant API surface (`ProviderScope`, `ConsumerStatefulWidget`,
`ConsumerState`, `ref.read/watch`) that is overkill for this use case, and the
`ChangeNotifier` pattern requires manual `notifyListeners()` calls.

## Proposed Solution

Replace `flutter_riverpod` with the `signals` package (^6.3.0). Signals provide
fine-grained reactivity with less boilerplate: state changes propagate automatically
to listeners without explicit notification calls, and widgets rebuild via a lightweight
`Watch` widget or mixin instead of requiring a custom widget base class.

## Scope

- Remove `flutter_riverpod` dependency, add `signals: ^6.3.0`
- Convert `ImageCacheManager` from `ChangeNotifier` to a plain class with signal-backed state
- Replace `ProviderScope` in `main.dart` with a simple top-level instance or signal
- Convert `ConsumerStatefulWidget`/`ConsumerState` back to standard `StatefulWidget`/`State`
- Replace all `ref.read(imageCacheProvider)` call sites

## Non-Goals

- Refactoring camera logic, image conversion, or navigation
- Changing the `ImageCacheManager` API beyond what's needed for signals
- Adding new features or state
