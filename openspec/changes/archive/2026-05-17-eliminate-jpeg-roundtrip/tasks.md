# Tasks: Eliminate JPEG Roundtrip

- [x] Update `native/yuv_converter.c` to output RGBA (4 bytes/pixel) — add `0xFF` alpha byte after each RGB triplet in the conversion loop
- [x] Update `lib/native/yuv_converter_ffi.dart` buffer size from `width * height * 3` to `width * height * 4`
- [x] Update `lib/camera/image_converter.dart`: change `ChannelOrder.rgb` to `ChannelOrder.rgba` in `Image.fromBytes`
- [x] Rework `ProcessedImage` in `image_converter.dart`: replace `displayableBytes` (JPEG encode) with `displayImage` (async `ui.Image` via `decodeImageFromPixels`), add `dispose()` method
- [x] Update gallery grid tiles in `gallery_page.dart` to use `FutureBuilder<ui.Image>` + `RawImage` instead of `FutureBuilder<Uint8List>` + `Image.memory`
- [x] Update fullscreen viewer in `gallery_page.dart` to use same `RawImage` pattern
- [x] Add `dispose()` calls for `ProcessedImage` in `_GalleryPageState.dispose()` and when images are removed via `_applyDeletion`
- [x] Test on device: verify gallery grid loads noticeably faster, fullscreen viewer works, save-to-gallery still produces valid JPEG (manual)
