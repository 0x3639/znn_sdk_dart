# Zenon Dart SDK 

[![Tests for znn_sdk_dart](https://github.com/alienc0der/znn_sdk_dart/actions/workflows/znn_sdk_tests.yml/badge.svg?branch=cicd)](https://github.com/alienc0der/znn_sdk_dart/actions/workflows/znn_sdk_tests.yml)

Reference implementation for the Zenon SDK for Dart and Flutter apps compatible with the Zenon Alphanet - Network of Momentum Phase 0. It provides a simple integration with any Dart or Flutter based projects.

## Setup

To start using this library, edit the `pubspec.yaml` by adding the following lines:

```yaml
dependencies:
  znn_sdk_dart: ^latest_version
```

> Notice: `znn_sdk_dart` requires Dart version `>=3.7.0`

You can also use a specific GitHub tag or branch:

```yaml
dependencies:
  znn_sdk_dart:
    git:
      url: git://github.com/zenon-network/znn_sdk_dart.git
      ref: <tag_or_branch>
```

## Mobile Support (Android & iOS)

`znn_sdk_dart` remains 100% pure Dart (no Flutter or `path_provider` dependency). When integrating into an Android or iOS app:

### 1. Configure Storage Paths

Desktop platforms lazily resolve default paths (`~/.znn` on Linux, `~/Library/znn` on macOS, `%AppData%/znn` on Windows). On Android and iOS, accessing default paths or `Zenon().keyStoreManager` before configuring throws a `StateError`. Call `configureZnnPaths(...)` during app startup (for example, using directories resolved via `path_provider` in a Flutter app):

```dart
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:znn_sdk_dart/znn_sdk_dart.dart';

void initMobilePaths(Directory appSupportDir, Directory appCacheDir) {
  final mainDir = Directory(path.join(appSupportDir.path, 'znn'));
  configureZnnPaths(
    ZnnPaths(
      main: mainDir,
      wallet: Directory(path.join(mainDir.path, 'wallet')),
      cache: Directory(path.join(appCacheDir.path, 'syrius')),
    ),
  );
  ensureDirectoriesExist();
}
```

`Zenon().keyStoreManager` resolves lazily from `znnDefaultWalletDirectory` and automatically stays in sync when `configureZnnPaths(...)` is called (while preserving explicit custom `WalletManager` overrides).

### 2. Native Libraries (PoW & Argon2)

- **Android:** Package ABI-matched `libpow_links.so` and `libargon2_ffi.so` under `android/app/src/main/jniLibs/<abi>/` (e.g. `arm64-v8a`, `x86_64`). The SDK opens `libpow_links.so` and `libargon2_ffi.so` directly via Android's dynamic linker. For Android 15+ and Google Play compliance, native `.so` binaries must be built with **16 KB ELF page alignment** (NDK r27+ / `-Wl,-z,max-page-size=16384`).
- **iOS:** Embed dynamic frameworks (`pow_links.xcframework` / `argon2_ffi.xcframework`) or link the libraries statically into the app binary. On iOS, the SDK resolves symbols in order: embedded framework (`pow_links.framework/pow_links` or `argon2_ffi.framework/argon2_ffi`), then `DynamicLibrary.process()`, then `DynamicLibrary.executable()`.
- **Custom Loaders:** If your app bundles native libraries at custom locations or via custom loading hooks, override resolution with:
  - `configurePoWLibraryLoader(PowLibraryLoader? loader, {String? libraryPath})` — pass `libraryPath` as well if `generatePoW(...)` needs a non-default path inside its worker isolate; pass `null` to restore default platform resolution.
  - `configureArgon2LibraryLoader(Argon2LibraryLoader? loader)` — pass `null` to restore default platform resolution.

## Contributing

Please check CONTRIBUTING for more details.

## License

The MIT License (MIT). Please check LICENSE for more information.
